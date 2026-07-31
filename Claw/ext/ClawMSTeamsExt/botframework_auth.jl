# botframework_auth.jl — inbound authentication for the Teams webhook (§2.1)
#
# `MSTeams.run_server` validates nothing and (until this change) bound 0.0.0.0:3978,
# so any POST to /api/messages minted a "user message" event that Claw evaluated
# with the owner's full tool set. This file implements the Bot Framework's actual
# inbound contract: every activity Microsoft sends carries
# `Authorization: Bearer <JWT>`, signed by a key published at the Bot Framework
# OpenID configuration, issued by `https://api.botframework.com`, with `aud` equal
# to the bot's app id.
#
# Why the verification is written out longhand instead of using a JWT library: no
# JWT package is in this stack's manifest (JWTs.jl exists in the depot only as an
# unrelated package's dependency), and RS256 verification is a public-key operation
# — `s^e mod n` plus a PKCS#1 v1.5 padding check — that Julia's stdlib already has
# everything for (`SHA` for the digest, GMP `powermod` for the exponentiation).
# There are no secrets in this computation, so the usual "never hand-roll crypto"
# timing concerns do not apply; a wrong answer here fails closed.
#
# What is *not* solvable inside MSTeams.jl: the handler `run_server` invokes only
# receives the parsed activity dict, never the request, so the Authorization header
# is unreachable from there. Rather than block on an upstream change, this extension
# serves the HTTP itself and delegates routing to `MSTeams.build_server_handler`, so
# the auth check runs strictly before any event is created.

const BF_OPENID_CONFIG_URL = "https://login.botframework.com/v1/.well-known/openidconfiguration"
const BF_DEFAULT_ISSUERS = String["https://api.botframework.com"]

# EMSA-PKCS1-v1_5 DigestInfo prefix for SHA-256 (RFC 8017 §9.2, notes).
const BF_SHA256_DIGESTINFO = UInt8[
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
]

struct BFRSAKey
    n::BigInt
    e::BigInt
    endorsements::Set{String}
end

"""
    BotFrameworkKeys

Cached signing keys from the Bot Framework OpenID configuration. Refreshed after
`max_cache_age_s` or on an unknown `kid` (Microsoft rotates keys without warning),
but no more often than `min_refresh_interval_s`. The attempt limit also applies when
the cache is empty, so a forged-token flood cannot amplify a metadata outage.
"""
mutable struct BotFrameworkKeys
    openid_url::String
    keys::Dict{String, BFRSAKey}
    fetched_at::Float64
    last_attempt_at::Float64
    min_refresh_interval_s::Float64
    max_cache_age_s::Float64
    lock::ReentrantLock
end

function BotFrameworkKeys(openid_url::AbstractString = BF_OPENID_CONFIG_URL;
        min_refresh_interval_s::Real = 60.0,
        max_cache_age_s::Real = 24 * 60 * 60,
    )
    (isfinite(min_refresh_interval_s) && min_refresh_interval_s >= 0) ||
        throw(ArgumentError("min_refresh_interval_s must be finite and nonnegative"))
    (isfinite(max_cache_age_s) && max_cache_age_s > 0) ||
        throw(ArgumentError("max_cache_age_s must be finite and positive"))
    BotFrameworkKeys(String(openid_url), Dict{String, BFRSAKey}(), 0.0, 0.0,
        Float64(min_refresh_interval_s), Float64(max_cache_age_s), ReentrantLock())
end

# ─── base64url ───

function _bf_b64url_decode(s::AbstractString)
    t = replace(String(s), '-' => '+', '_' => '/')
    pad = mod(-length(t), 4)
    pad == 3 && throw(ArgumentError("invalid base64url length"))
    return Base64.base64decode(t * repeat("=", pad))
end

_bf_bytes_to_bigint(bytes::AbstractVector{UInt8}) =
    foldl((acc, b) -> (acc << 8) | BigInt(b), bytes; init = BigInt(0))

function _bf_bigint_to_bytes(x::BigInt, len::Int)
    out = zeros(UInt8, len)
    v = x
    for i in len:-1:1
        out[i] = UInt8(v & 0xff)
        v >>= 8
    end
    v == 0 || return UInt8[]     # value does not fit the modulus width
    return out
end

# Length-independent comparison. The digest being compared is public, but the habit
# is cheap and keeps this function safe if it is ever reused on a secret.
function _bf_consttime_eq(a::AbstractVector{UInt8}, b::AbstractVector{UInt8})
    length(a) == length(b) || return false
    diff = 0x00
    for i in eachindex(a)
        diff |= a[i] ⊻ b[i]
    end
    return diff == 0x00
end

# ─── Key set ───

function _bf_fetch_keys(openid_url::AbstractString)
    config = JSON.parse(String(HTTP.get(openid_url; request_timeout = 10, retry = false).body))
    jwks_uri = get(() -> nothing, config, "jwks_uri")
    jwks_uri === nothing && error("Bot Framework OpenID config has no jwks_uri")
    jwks = JSON.parse(String(HTTP.get(String(jwks_uri); request_timeout = 10, retry = false).body))
    raw_keys = get(() -> nothing, jwks, "keys")
    raw_keys isa AbstractVector || error("Bot Framework JWKS has no key array")
    keys = Dict{String, BFRSAKey}()
    for k in raw_keys
        k isa AbstractDict || continue
        get(() -> nothing, k, "kty") == "RSA" || continue
        use = get(() -> nothing, k, "use")
        (use === nothing || use == "sig") || continue
        alg = get(() -> nothing, k, "alg")
        (alg === nothing || alg == "RS256") || continue
        kid = get(() -> nothing, k, "kid")
        n = get(() -> nothing, k, "n")
        e = get(() -> nothing, k, "e")
        (kid isa AbstractString && n isa AbstractString && e isa AbstractString) || continue
        endorsements_raw = get(() -> Any[], k, "endorsements")
        endorsements_raw isa AbstractVector || continue
        endorsements = Set{String}(
            lowercase(String(v)) for v in endorsements_raw if v isa AbstractString)
        key = try
            BFRSAKey(
                _bf_bytes_to_bigint(_bf_b64url_decode(n)),
                _bf_bytes_to_bigint(_bf_b64url_decode(e)),
                endorsements,
            )
        catch
            continue
        end
        (key.n > 0 && key.e > 0) || continue
        keys[String(kid)] = key
    end
    isempty(keys) && error("Bot Framework JWKS contained no usable RSA keys")
    return keys
end

"""
    _bf_refresh_keys!(cache; force = false) -> Bool

Fetch the key set, rate-limited to one attempt per `min_refresh_interval_s`.
Returns whether the cache now holds keys; failures leave the previous set in place
so a transient network blip does not lock out every subsequent activity.
"""
function _bf_refresh_keys!(cache::BotFrameworkKeys; force::Bool = false)
    return lock(cache.lock) do
        now = time()
        fresh = !isempty(cache.keys) && (now - cache.fetched_at) < cache.max_cache_age_s
        if !force && fresh
            return true
        end
        if (now - cache.last_attempt_at) < cache.min_refresh_interval_s
            return !isempty(cache.keys)
        end
        cache.last_attempt_at = now
        try
            cache.keys = _bf_fetch_keys(cache.openid_url)
            cache.fetched_at = now
            @debug "ClawMSTeamsExt: refreshed Bot Framework signing keys" count = length(cache.keys)
        catch e
            @warn "ClawMSTeamsExt: could not refresh Bot Framework signing keys" exception = (e,) maxlog = 5
        end
        return !isempty(cache.keys)
    end
end

function _bf_lookup_key(cache::BotFrameworkKeys, kid::AbstractString)
    # This is a no-op while the cache is younger than 24 hours. It also performs
    # the required periodic refresh before a still-present but revoked key is used.
    _bf_refresh_keys!(cache)
    key = lock(cache.lock) do
        get(cache.keys, String(kid), nothing)
    end
    key === nothing || return key
    # Unknown kid ⇒ Microsoft probably rotated. Refresh once, then look again.
    _bf_refresh_keys!(cache; force = true)
    return lock(cache.lock) do
        get(cache.keys, String(kid), nothing)
    end
end

# ─── Signature ───

"""
    _bf_rsa_verify(key, signing_input, signature) -> Bool

RSASSA-PKCS1-v1_5 with SHA-256. `s^e mod n` recovers the encoded message, which must
be `0x00 || 0x01 || 0xFF…(≥8) || 0x00 || DigestInfo(SHA-256(signing_input))`. Any
deviation — wrong length, wrong padding, short PS, wrong digest — is a rejection.
"""
function _bf_rsa_verify(key::BFRSAKey, signing_input::AbstractString, signature::AbstractVector{UInt8})
    k = cld(ndigits(key.n; base = 2), 8)
    length(signature) == k || return false
    s = _bf_bytes_to_bigint(signature)
    s < key.n || return false
    em = _bf_bigint_to_bytes(powermod(s, key.e, key.n), k)
    length(em) == k || return false
    (em[1] == 0x00 && em[2] == 0x01) || return false
    i = 3
    while i <= k && em[i] == 0xff
        i += 1
    end
    (i - 3) >= 8 || return false          # PS must be at least 8 octets
    (i <= k && em[i] == 0x00) || return false
    digest_info = @view em[(i + 1):end]
    expected = vcat(BF_SHA256_DIGESTINFO, SHA.sha256(codeunits(String(signing_input))))
    return _bf_consttime_eq(digest_info, expected)
end

# ─── Token verification ───

_bf_claim_string(claims, name) = let v = get(() -> nothing, claims, name)
    v isa AbstractString ? String(v) : nothing
end

_bf_claim_number(claims, name) = let v = get(() -> nothing, claims, name)
    # `Bool <: Number` in Julia, but JSON booleans are not JWT NumericDate values.
    value = if v isa Number && !(v isa Bool)
        try
            Float64(v)
        catch
            nothing
        end
    elseif v isa AbstractString
        tryparse(Float64, v)
    else
        nothing
    end
    value !== nothing && isfinite(value) ? value : nothing
end

"""
    verify_bot_framework_token(cache, token;
        app_id, service_url, channel_id, issuers, clock_skew_s)
        -> (ok::Bool, reason::String)

Full inbound check: RS256 only (an `alg` of `none` or `HS256` is the classic JWT
forgery and is refused outright), signature against the published key for the
token's `kid`, `iss` in `issuers`, `aud` equal to this bot's app id, `exp`/`nbf`
inside a small clock skew, the token's `serviceurl` claim equal to the Activity
`serviceUrl`, and a signing-key endorsement for the Activity `channelId`. Returns a
reason so a rejection is diagnosable without logging the token.
"""
function verify_bot_framework_token(cache::BotFrameworkKeys, token::AbstractString;
        app_id::AbstractString,
        service_url::AbstractString,
        channel_id::AbstractString,
        issuers::AbstractVector{<:AbstractString} = BF_DEFAULT_ISSUERS,
        clock_skew_s::Real = 300.0,
    )
    (isfinite(clock_skew_s) && clock_skew_s >= 0) ||
        return (false, "clock skew must be finite and nonnegative")
    isempty(service_url) && return (false, "activity has no serviceUrl")
    isempty(channel_id) && return (false, "activity has no channelId")
    parts = split(String(token), '.')
    length(parts) == 3 || return (false, "malformed token (expected 3 dot-separated parts)")
    header = try
        JSON.parse(String(_bf_b64url_decode(parts[1])))
    catch
        return (false, "unparseable token header")
    end
    header isa AbstractDict || return (false, "token header is not an object")

    alg = _bf_claim_string(header, "alg")
    alg == "RS256" || return (false, "unsupported alg '$(something(alg, "none"))' (only RS256 is accepted)")
    kid = _bf_claim_string(header, "kid")
    kid === nothing && return (false, "token header has no kid")

    key = _bf_lookup_key(cache, kid)
    key === nothing && return (false, "no published signing key for kid '$kid'")

    signature = try
        _bf_b64url_decode(parts[3])
    catch
        return (false, "unparseable signature")
    end
    signing_input = string(parts[1], ".", parts[2])
    _bf_rsa_verify(key, signing_input, signature) || return (false, "signature verification failed")

    claims = try
        JSON.parse(String(_bf_b64url_decode(parts[2])))
    catch
        return (false, "unparseable token claims")
    end
    claims isa AbstractDict || return (false, "token claims are not an object")

    iss = _bf_claim_string(claims, "iss")
    (iss !== nothing && iss in issuers) || return (false, "issuer '$(something(iss, "(none)"))' is not trusted")

    aud = _bf_claim_string(claims, "aud")
    aud == String(app_id) || return (false, "audience '$(something(aud, "(none)"))' is not this bot's app id")

    now = time()
    exp = _bf_claim_number(claims, "exp")
    exp === nothing && return (false, "token has no valid exp claim")
    exp + clock_skew_s < now && return (false, "token expired")
    nbf = _bf_claim_number(claims, "nbf")
    nbf === nothing && return (false, "token has no valid nbf claim")
    exp >= nbf || return (false, "token exp precedes nbf")
    nbf - clock_skew_s > now && return (false, "token not valid yet")

    # Bot Framework uses the historical lowercase claim name `serviceurl`, while
    # the Activity JSON property is camel-case `serviceUrl`.
    claimed_service_url = _bf_claim_string(claims, "serviceurl")
    claimed_service_url == String(service_url) ||
        return (false, "serviceurl claim does not match the activity serviceUrl")

    normalized_channel_id = lowercase(String(channel_id))
    normalized_channel_id in key.endorsements ||
        return (false, "signing key has no endorsement for channel '$channel_id'")

    return (true, "ok")
end

"""
    _bf_authorize(req, source, cache) -> (ok::Bool, reason::String)

Pull the bearer token out of the request and verify it. A missing or malformed
`Authorization` header is a rejection: unauthenticated activities are precisely the
attack this exists to stop.
"""
function _bf_authorize(req::HTTP.Request, source, cache::BotFrameworkKeys)
    raw = HTTP.header(req, "Authorization", "")
    isempty(raw) && return (false, "missing Authorization header")
    m = match(r"^\s*[Bb]earer\s+(\S+)\s*$", String(raw))
    m === nothing && return (false, "Authorization header is not a bearer token")
    activity = try
        JSON.parse(String(req.body))
    catch
        return (false, "activity body is not valid JSON")
    end
    activity isa AbstractDict || return (false, "activity body is not an object")
    service_url = _bf_claim_string(activity, "serviceUrl")
    service_url === nothing && return (false, "activity has no valid serviceUrl")
    channel_id = _bf_claim_string(activity, "channelId")
    channel_id === nothing && return (false, "activity has no valid channelId")
    return verify_bot_framework_token(cache, String(m.captures[1]);
        app_id = strip(source.app_id),
        service_url,
        channel_id,
        issuers = source.issuers,
        clock_skew_s = source.clock_skew_s)
end
