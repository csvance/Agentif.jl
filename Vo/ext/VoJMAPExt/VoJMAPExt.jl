module VoJMAPExt

using JMAP
using JMAP: HTTP, JSON
import Agentif
import Vo

export FastmailEventSource

# ─── Helpers ───

function _to_snake_case(s::AbstractString)
    buf = IOBuffer()
    for (i, c) in enumerate(s)
        if isuppercase(c)
            i > 1 && write(buf, '_')
            write(buf, lowercase(c))
        else
            write(buf, c)
        end
    end
    return String(take!(buf))
end

function _fmt_addrs(addrs)
    addrs === nothing && return ""
    parts = String[]
    for a in addrs
        push!(parts, a.name !== nothing && !isempty(a.name) ? "$(a.name) <$(a.email)>" : a.email)
    end
    return join(parts, ", ")
end

function _parse_addrs(s::String)
    return [Dict{String,Any}("email" => strip(a)) for a in split(s, ",") if !isempty(strip(a))]
end

# ─── Event ───

struct JMAPStateChangeEvent <: Vo.Event
    kind::String                    # "Email", "EmailDelivery", "Mailbox", etc.
    account_id::String
    new_state::String
    created::Vector{String}
    updated::Vector{String}
    destroyed::Vector{String}
end

Vo.get_name(ev::JMAPStateChangeEvent) = "jmap_$(_to_snake_case(ev.kind))"
Vo.get_session_key(ev::JMAPStateChangeEvent) = "jmap:$(ev.account_id):$(ev.kind)"

function Vo.event_content(ev::JMAPStateChangeEvent)
    lines = String["[JMAP $(ev.kind) state change for account $(ev.account_id)]"]
    !isempty(ev.created) && push!(lines, "Created ($(length(ev.created))): $(join(first(ev.created, 10), ", "))$(length(ev.created) > 10 ? "..." : "")")
    !isempty(ev.updated) && push!(lines, "Updated ($(length(ev.updated))): $(join(first(ev.updated, 10), ", "))$(length(ev.updated) > 10 ? "..." : "")")
    !isempty(ev.destroyed) && push!(lines, "Destroyed ($(length(ev.destroyed))): $(join(first(ev.destroyed, 10), ", "))$(length(ev.destroyed) > 10 ? "..." : "")")
    isempty(ev.created) && isempty(ev.updated) && isempty(ev.destroyed) && push!(lines, "State updated to: $(ev.new_state)")
    return join(lines, "\n")
end

# ─── Event types ───

const JMAP_STATE_CHANGE_TYPES = [
    "Email", "EmailDelivery", "Mailbox", "Thread",
    "Identity", "EmailSubmission", "VacationResponse",
]

const ALL_EVENT_TYPES = [
    Vo.EventType("jmap_$(_to_snake_case(t))", "JMAP $t state change")
    for t in JMAP_STATE_CHANGE_TYPES
]

# ─── Session holder (set during start!) ───

const JMAP_SESSION = Ref{Union{Nothing, JMAP.Session}}(nothing)

function _get_session()
    s = JMAP_SESSION[]
    s === nothing && error("No JMAP session initialized. Is FastmailEventSource started?")
    return s
end

# ─── EventSource ───

Base.@kwdef mutable struct FastmailEventSource <: Vo.EventSource
    token::String = get(ENV, "JMAP_API_TOKEN", "")
    session_url::String = get(ENV, "JMAP_SESSION_URL", "")
    types::String = "*"
    ping::Int = 30
    _states::Dict{String, Dict{String, String}} = Dict{String, Dict{String, String}}()
    _session::Union{Nothing, JMAP.Session} = nothing
end

Vo.get_event_types(::FastmailEventSource) = ALL_EVENT_TYPES
Vo.get_channels(::FastmailEventSource) = Agentif.AbstractChannel[]
Vo.get_event_handlers(::FastmailEventSource) = Vo.EventHandler[]
Vo.get_tools(::FastmailEventSource) = JMAP_TOOLS

# ─── Changes dispatch ───

const CHANGES_FUNCTIONS = Dict{String, Function}(
    "Email" => JMAP.email_changes,
    "Mailbox" => JMAP.mailbox_changes,
    "Thread" => JMAP.thread_changes,
)

function _fetch_changes(session::JMAP.Session, type_name::String, since_state::String, account_id::String)
    changes_fn = get(CHANGES_FUNCTIONS, type_name, nothing)
    changes_fn === nothing && return (String[], String[], String[], since_state)
    try
        resp = changes_fn(session, since_state; account_id=account_id)
        return (resp.created, resp.updated, resp.destroyed, resp.newState)
    catch e
        @warn "VoJMAPExt: failed to fetch $type_name/changes" exception=(e, catch_backtrace())
        return (String[], String[], String[], since_state)
    end
end

# ─── SSE loop ───

function _sse_loop(source::FastmailEventSource, assistant::Vo.AgentAssistant)
    session = source._session
    session === nothing && error("VoJMAPExt: no JMAP session")

    backoff = 1.0
    max_backoff = 60.0

    while true
        try
            @info "VoJMAPExt: connecting to SSE" types=source.types ping=source.ping
            JMAP.listen_events(session; types=source.types, ping=source.ping) do sc::JMAP.StateChange
                backoff = 1.0  # reset on successful event
                for (account_id, type_states) in sc.changed
                    account_states = get!(() -> Dict{String,String}(), source._states, account_id)
                    for (type_name, new_state) in type_states
                        old_state = get(account_states, type_name, "")
                        new_state == old_state && continue

                        created, updated, destroyed, resolved_state = if !isempty(old_state)
                            _fetch_changes(session, type_name, old_state, account_id)
                        else
                            (String[], String[], String[], new_state)
                        end
                        account_states[type_name] = resolved_state

                        ev = JMAPStateChangeEvent(type_name, account_id, resolved_state, created, updated, destroyed)
                        @info "VoJMAPExt: state change" type=type_name account=account_id created=length(created) updated=length(updated) destroyed=length(destroyed)
                        put!(assistant.event_queue, ev)
                    end
                end
            end
        catch e
            if e isa InterruptException
                @info "VoJMAPExt: SSE interrupted"
                break
            end
            @warn "VoJMAPExt: SSE connection error, reconnecting in $(backoff)s" exception=(e, catch_backtrace())
            sleep(backoff)
            backoff = min(backoff * 2, max_backoff)
        end
    end
end

# ─── Initial state seeding ───

function _seed_initial_states!(source::FastmailEventSource)
    session = source._session
    session === nothing && return
    account_id = session.mailAccountId
    account_id === nothing && return

    account_states = get!(() -> Dict{String,String}(), source._states, account_id)

    try
        resp = JMAP.email_get(session; ids=String[])
        account_states["Email"] = resp.state
    catch e
        @warn "VoJMAPExt: failed to seed Email state" exception=(e, catch_backtrace())
    end

    try
        resp = JMAP.mailbox_get(session)
        account_states["Mailbox"] = resp.state
    catch e
        @warn "VoJMAPExt: failed to seed Mailbox state" exception=(e, catch_backtrace())
    end

    @info "VoJMAPExt: seeded initial states" account=account_id types=collect(keys(account_states))
end

# ─── start! ───

function Vo.start!(source::FastmailEventSource, assistant::Vo.AgentAssistant)
    token = strip(source.token)
    isempty(token) && error("VoJMAPExt: JMAP_API_TOKEN not set")

    session_url = strip(source.session_url)
    session = if isempty(session_url)
        JMAP.Session(token=token)
    else
        JMAP.Session(token=token, session_url=session_url)
    end

    source._session = session
    JMAP_SESSION[] = session

    _seed_initial_states!(source)

    errormonitor(Threads.@spawn begin
        _sse_loop(source, assistant)
    end)
end

# ═══════════════════════════════════════════════════════════
# Tools
# ═══════════════════════════════════════════════════════════

# ─── email_search ───

const EMAIL_SEARCH_TOOL = Agentif.@tool "Search emails by text query, sender, subject, date range, mailbox, or keywords. Returns matching email summaries sorted by date." function email_search(
        query::Union{Nothing, String} = nothing,
        from::Union{Nothing, String} = nothing,
        to::Union{Nothing, String} = nothing,
        subject::Union{Nothing, String} = nothing,
        in_mailbox::Union{Nothing, String} = nothing,
        after::Union{Nothing, String} = nothing,
        before::Union{Nothing, String} = nothing,
        has_keyword::Union{Nothing, String} = nothing,
        not_keyword::Union{Nothing, String} = nothing,
        limit::Union{Nothing, Int} = nothing
    )
    session = _get_session()
    n = limit === nothing ? 20 : min(limit, 50)

    filter = Dict{String,Any}()
    query !== nothing && (filter["text"] = query)
    from !== nothing && (filter["from"] = from)
    to !== nothing && (filter["to"] = to)
    subject !== nothing && (filter["subject"] = subject)
    in_mailbox !== nothing && (filter["inMailbox"] = in_mailbox)
    after !== nothing && (filter["after"] = after)
    before !== nothing && (filter["before"] = before)
    has_keyword !== nothing && (filter["hasKeyword"] = has_keyword)
    not_keyword !== nothing && (filter["notKeyword"] = not_keyword)

    sort = [Dict{String,Any}("property" => "receivedAt", "isAscending" => false)]
    ids = JMAP.email_query_ids(session; filter=isempty(filter) ? nothing : filter, sort=sort, limit=n)
    isempty(ids) && return "No emails found matching the search criteria."

    emails = JMAP.fetch_emails(session, ids;
        properties=["id", "threadId", "mailboxIds", "keywords", "from", "to", "subject", "receivedAt", "preview", "hasAttachment"])

    lines = String[]
    for e in emails
        from_str = _fmt_addrs(e.from)
        isempty(from_str) && (from_str = "(unknown)")
        flags = String[]
        haskey(e.keywords, "\$seen") || push!(flags, "UNREAD")
        haskey(e.keywords, "\$flagged") && push!(flags, "FLAGGED")
        haskey(e.keywords, "\$muted") && push!(flags, "MUTED")
        e.hasAttachment === true && push!(flags, "ATTACHMENT")
        flag_str = isempty(flags) ? "" : " [$(join(flags, ", "))]"

        push!(lines, "ID: $(e.id) | Thread: $(something(e.threadId, "?"))$flag_str")
        push!(lines, "  From: $from_str")
        push!(lines, "  Subject: $(something(e.subject, "(no subject)"))")
        push!(lines, "  Date: $(something(e.receivedAt, "?"))")
        push!(lines, "  Preview: $(something(e.preview, ""))")
        push!(lines, "")
    end
    return join(lines, "\n")
end

# ─── email_read ───

const EMAIL_READ_TOOL = Agentif.@tool "Read the full content of an email by its ID. Returns headers, body text, and attachment info." function email_read(email_id::String)
    session = _get_session()
    emails = JMAP.fetch_emails(session, [email_id];
        properties=["id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "bcc",
                     "replyTo", "subject", "sentAt", "receivedAt", "messageId", "inReplyTo",
                     "references", "hasAttachment", "preview", "textBody", "htmlBody",
                     "attachments", "bodyValues"],
        fetch_text_body_values=true,
        max_body_value_bytes=256_000)
    isempty(emails) && return "Email not found: $email_id"
    e = emails[1]

    lines = String[]
    push!(lines, "ID: $(e.id)")
    push!(lines, "Thread: $(something(e.threadId, "?"))")
    push!(lines, "From: $(_fmt_addrs(e.from))")
    push!(lines, "To: $(_fmt_addrs(e.to))")
    e.cc !== nothing && !isempty(e.cc) && push!(lines, "Cc: $(_fmt_addrs(e.cc))")
    push!(lines, "Subject: $(something(e.subject, "(no subject)"))")
    push!(lines, "Date: $(something(e.sentAt, something(e.receivedAt, "?")))")

    flags = String[]
    haskey(e.keywords, "\$seen") || push!(flags, "UNREAD")
    haskey(e.keywords, "\$flagged") && push!(flags, "FLAGGED")
    haskey(e.keywords, "\$answered") && push!(flags, "ANSWERED")
    haskey(e.keywords, "\$draft") && push!(flags, "DRAFT")
    haskey(e.keywords, "\$muted") && push!(flags, "MUTED")
    !isempty(flags) && push!(lines, "Flags: $(join(flags, ", "))")
    push!(lines, "")

    if !isempty(e.textBody)
        for part in e.textBody
            bv = get(e.bodyValues, part.partId, nothing)
            if bv !== nothing
                push!(lines, bv.value)
                bv.isTruncated && push!(lines, "[body truncated]")
            end
        end
    else
        push!(lines, "(no text body)")
    end

    if !isempty(e.attachments)
        push!(lines, "")
        push!(lines, "Attachments:")
        for att in e.attachments
            name = something(att.name, "(unnamed)")
            size_str = att.size !== nothing ? " ($(att.size) bytes)" : ""
            push!(lines, "  - $name$size_str [$(something(att.type, "?"))]")
        end
    end

    return join(lines, "\n")
end

# ─── email_send ───

const EMAIL_SEND_TOOL = Agentif.@tool "Compose and send a new email. Provide to address(es) comma-separated, subject, and body text." function email_send(
        to::String,
        subject::String,
        body::String,
        cc::Union{Nothing, String} = nothing,
        bcc::Union{Nothing, String} = nothing
    )
    session = _get_session()

    identities = JMAP.list_identities(session)
    isempty(identities) && return "Error: no sending identities configured"
    identity = identities[1]

    mailboxes = JMAP.list_mailboxes(session)
    drafts_mb = nothing
    sent_mb = nothing
    for mb in mailboxes
        mb.role == "drafts" && (drafts_mb = mb)
        mb.role == "sent" && (sent_mb = mb)
    end
    drafts_mb === nothing && return "Error: no Drafts mailbox found"

    draft = Dict{String,Any}(
        "from" => [Dict{String,Any}("name" => identity.name, "email" => identity.email)],
        "to" => _parse_addrs(to),
        "subject" => subject,
        "textBody" => [Dict{String,Any}("partId" => "body", "type" => "text/plain")],
        "bodyValues" => Dict{String,Any}("body" => Dict{String,Any}("value" => body)),
        "mailboxIds" => Dict{String,Any}(drafts_mb.id => true),
        "keywords" => Dict{String,Any}("\$seen" => true),
    )
    cc !== nothing && (draft["cc"] = _parse_addrs(cc))
    bcc !== nothing && (draft["bcc"] = _parse_addrs(bcc))

    create_id = "draft1"
    set_resp = JMAP.email_set(session; create=Dict{String,Any}(create_id => draft))
    created = set_resp.created
    (created === nothing || !haskey(created, create_id)) && return "Error: failed to create draft — $(something(set_resp.notCreated, "unknown error"))"
    email_id = created[create_id].id

    submission = Dict{String,Any}(
        "sub1" => Dict{String,Any}(
            "emailId" => email_id,
            "identityId" => identity.id,
        )
    )
    on_success = if sent_mb !== nothing
        Dict{String,Any}("#sub1" => Dict{String,Any}(
            "mailboxIds/$(drafts_mb.id)" => nothing,
            "mailboxIds/$(sent_mb.id)" => true,
            "keywords/\$draft" => nothing,
        ))
    else
        nothing
    end

    JMAP.email_submission_set(session; create=submission, on_success_update_email=on_success)
    return "Email sent to $to (subject: $subject)"
end

# ─── email_reply ───

const EMAIL_REPLY_TOOL = Agentif.@tool "Reply to an email by its ID. Automatically threads the reply and sets In-Reply-To headers. Set reply_all to 'true' to reply to all recipients." function email_reply(
        email_id::String,
        body::String,
        reply_all::Union{Nothing, String} = nothing
    )
    session = _get_session()
    originals = JMAP.fetch_emails(session, [email_id];
        properties=["id", "from", "to", "cc", "replyTo", "subject", "messageId", "references", "threadId"])
    isempty(originals) && return "Email not found: $email_id"
    orig = originals[1]

    identities = JMAP.list_identities(session)
    isempty(identities) && return "Error: no sending identities configured"
    identity = identities[1]
    my_email = lowercase(identity.email)

    reply_to = orig.replyTo !== nothing && !isempty(orig.replyTo) ? orig.replyTo : orig.from
    to_addrs = reply_to !== nothing ? join([a.email for a in reply_to], ",") : ""
    isempty(to_addrs) && return "Error: cannot determine reply address"

    cc_addrs = nothing
    if reply_all == "true" || reply_all == "yes"
        all_ccs = String[]
        for addrs in [orig.to, orig.cc]
            addrs === nothing && continue
            for a in addrs
                lowercase(a.email) == my_email && continue
                push!(all_ccs, a.email)
            end
        end
        !isempty(all_ccs) && (cc_addrs = join(all_ccs, ","))
    end

    subj = something(orig.subject, "")
    startswith(lowercase(subj), "re:") || (subj = "Re: $subj")

    # Build threaded draft
    mailboxes = JMAP.list_mailboxes(session)
    drafts_mb = nothing
    sent_mb = nothing
    for mb in mailboxes
        mb.role == "drafts" && (drafts_mb = mb)
        mb.role == "sent" && (sent_mb = mb)
    end
    drafts_mb === nothing && return "Error: no Drafts mailbox found"

    draft = Dict{String,Any}(
        "from" => [Dict{String,Any}("name" => identity.name, "email" => identity.email)],
        "to" => _parse_addrs(to_addrs),
        "subject" => subj,
        "textBody" => [Dict{String,Any}("partId" => "body", "type" => "text/plain")],
        "bodyValues" => Dict{String,Any}("body" => Dict{String,Any}("value" => body)),
        "mailboxIds" => Dict{String,Any}(drafts_mb.id => true),
        "keywords" => Dict{String,Any}("\$seen" => true),
    )
    cc_addrs !== nothing && (draft["cc"] = _parse_addrs(cc_addrs))

    # Threading headers
    if orig.messageId !== nothing
        draft["inReplyTo"] = orig.messageId
        refs = String[]
        orig.references !== nothing && append!(refs, orig.references)
        append!(refs, orig.messageId)
        draft["references"] = refs
    end

    create_id = "reply1"
    set_resp = JMAP.email_set(session; create=Dict{String,Any}(create_id => draft))
    created = set_resp.created
    (created === nothing || !haskey(created, create_id)) && return "Error: failed to create reply draft"
    new_email_id = created[create_id].id

    submission = Dict{String,Any}(
        "sub1" => Dict{String,Any}(
            "emailId" => new_email_id,
            "identityId" => identity.id,
        )
    )
    on_success = if sent_mb !== nothing
        Dict{String,Any}("#sub1" => Dict{String,Any}(
            "mailboxIds/$(drafts_mb.id)" => nothing,
            "mailboxIds/$(sent_mb.id)" => true,
            "keywords/\$draft" => nothing,
        ))
    else
        nothing
    end

    JMAP.email_submission_set(session; create=submission, on_success_update_email=on_success)
    return "Reply sent (subject: $subj)"
end

# ─── email_forward ───

const EMAIL_FORWARD_TOOL = Agentif.@tool "Forward an email to new recipients. Optionally add a comment above the forwarded content." function email_forward(
        email_id::String,
        to::String,
        comment::Union{Nothing, String} = nothing
    )
    session = _get_session()
    originals = JMAP.fetch_emails(session, [email_id];
        properties=["id", "from", "to", "subject", "sentAt", "textBody", "bodyValues"],
        fetch_text_body_values=true,
        max_body_value_bytes=256_000)
    isempty(originals) && return "Email not found: $email_id"
    orig = originals[1]

    orig_body = ""
    if !isempty(orig.textBody)
        for part in orig.textBody
            bv = get(orig.bodyValues, part.partId, nothing)
            bv !== nothing && (orig_body *= bv.value)
        end
    end

    fwd_body = string(
        comment !== nothing ? "$comment\n\n" : "",
        "---------- Forwarded message ----------\n",
        "From: $(_fmt_addrs(orig.from))\n",
        "Date: $(something(orig.sentAt, "?"))\n",
        "Subject: $(something(orig.subject, "(no subject)"))\n",
        "To: $(_fmt_addrs(orig.to))\n\n",
        orig_body
    )

    subj = something(orig.subject, "")
    startswith(lowercase(subj), "fwd:") || (subj = "Fwd: $subj")

    return email_send(to, subj, fwd_body, nothing, nothing)
end

# ─── email_move ───

const EMAIL_MOVE_TOOL = Agentif.@tool "Move an email to a different mailbox. Use list_mailboxes to find mailbox IDs." function email_move(email_id::String, target_mailbox_id::String)
    session = _get_session()
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(email_id => Dict{String,Any}("mailboxIds" => Dict{String,Any}(target_mailbox_id => true))))
    return "Moved email $email_id to mailbox $target_mailbox_id"
end

# ─── email_archive ───

const EMAIL_ARCHIVE_TOOL = Agentif.@tool "Archive an email by moving it to the Archive mailbox." function email_archive(email_id::String)
    session = _get_session()
    mailboxes = JMAP.list_mailboxes(session)
    archive_mb = nothing
    for mb in mailboxes
        mb.role == "archive" && (archive_mb = mb; break)
    end
    archive_mb === nothing && return "Error: no Archive mailbox found"
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(email_id => Dict{String,Any}("mailboxIds" => Dict{String,Any}(archive_mb.id => true))))
    return "Archived email $email_id"
end

# ─── email_trash ───

const EMAIL_TRASH_TOOL = Agentif.@tool "Move an email to the Trash mailbox." function email_trash(email_id::String)
    session = _get_session()
    mailboxes = JMAP.list_mailboxes(session)
    trash_mb = nothing
    for mb in mailboxes
        mb.role == "trash" && (trash_mb = mb; break)
    end
    trash_mb === nothing && return "Error: no Trash mailbox found"
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(email_id => Dict{String,Any}("mailboxIds" => Dict{String,Any}(trash_mb.id => true))))
    return "Trashed email $email_id"
end

# ─── email_flag ───

const EMAIL_FLAG_TOOL = Agentif.@tool "Set or clear a keyword flag on an email. Common keywords: \$seen (read), \$flagged (starred), \$answered, \$draft. Set action to 'set' or 'clear'." function email_flag(email_id::String, keyword::String, action::String)
    session = _get_session()
    value = lowercase(action) == "set" ? true : nothing
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(email_id => Dict{String,Any}("keywords/$keyword" => value)))
    act_past = lowercase(action) == "set" ? "Set" : "Cleared"
    return "$act_past keyword '$keyword' on email $email_id"
end

# ─── email_mark_read ───

const EMAIL_MARK_READ_TOOL = Agentif.@tool "Mark one or more emails as read. Provide comma-separated email IDs." function email_mark_read(email_ids::String)
    session = _get_session()
    ids = strip.(split(email_ids, ","))
    updates = Dict{String,Dict{String,Any}}()
    for id in ids
        updates[id] = Dict{String,Any}("keywords/\$seen" => true)
    end
    JMAP.email_set(session; update=updates)
    return "Marked $(length(ids)) email(s) as read"
end

# ─── list_mailboxes ───

const LIST_MAILBOXES_TOOL = Agentif.@tool "List all email mailboxes (folders) with their IDs, names, roles, and unread counts." function jmap_list_mailboxes()
    session = _get_session()
    mailboxes = JMAP.list_mailboxes(session)
    lines = String[]
    for mb in sort(mailboxes; by=m -> something(m.sortOrder, 999))
        role_str = mb.role !== nothing ? " ($(mb.role))" : ""
        unread = something(mb.unreadEmails, 0)
        total = something(mb.totalEmails, 0)
        push!(lines, "- $(mb.name)$role_str [id: $(mb.id)] ($unread unread / $total total)")
    end
    isempty(lines) ? "No mailboxes found" : join(lines, "\n")
end

# ─── email_thread ───

const EMAIL_THREAD_TOOL = Agentif.@tool "Get all emails in a thread by thread ID. Returns the full conversation." function email_thread(thread_id::String)
    session = _get_session()
    thread_resp = JMAP.thread_get(session; ids=[thread_id])
    isempty(thread_resp.list) && return "Thread not found: $thread_id"
    email_ids = thread_resp.list[1].emailIds
    isempty(email_ids) && return "Thread has no emails"

    emails = JMAP.fetch_emails(session, email_ids;
        properties=["id", "from", "to", "subject", "receivedAt", "preview", "keywords"])

    lines = String["Thread $thread_id ($(length(emails)) emails):", ""]
    for e in emails
        from_str = _fmt_addrs(e.from)
        isempty(from_str) && (from_str = "?")
        push!(lines, "[$from_str] $(something(e.subject, "(no subject)")) — $(something(e.receivedAt, "?"))")
        push!(lines, "  ID: $(e.id)")
        push!(lines, "  Preview: $(something(e.preview, ""))")
        push!(lines, "")
    end
    return join(lines, "\n")
end

# ─── email_mute_thread ───

const EMAIL_MUTE_THREAD_TOOL = Agentif.@tool "Mute an email thread. New replies will be auto-archived and marked as read by Fastmail." function email_mute_thread(thread_id::String)
    session = _get_session()
    thread_resp = JMAP.thread_get(session; ids=[thread_id])
    isempty(thread_resp.list) && return "Thread not found: $thread_id"
    email_ids = thread_resp.list[1].emailIds
    isempty(email_ids) && return "Thread has no emails"

    updates = Dict{String,Dict{String,Any}}()
    for id in email_ids
        updates[id] = Dict{String,Any}("keywords/\$muted" => true)
    end
    JMAP.email_set(session; update=updates)
    return "Muted thread $thread_id ($(length(email_ids)) emails). New replies will be auto-archived."
end

# ─── email_unmute_thread ───

const EMAIL_UNMUTE_THREAD_TOOL = Agentif.@tool "Unmute an email thread. New replies will arrive in inbox normally." function email_unmute_thread(thread_id::String)
    session = _get_session()
    thread_resp = JMAP.thread_get(session; ids=[thread_id])
    isempty(thread_resp.list) && return "Thread not found: $thread_id"
    email_ids = thread_resp.list[1].emailIds
    isempty(email_ids) && return "Thread has no emails"

    updates = Dict{String,Dict{String,Any}}()
    for id in email_ids
        updates[id] = Dict{String,Any}("keywords/\$muted" => nothing)
    end
    JMAP.email_set(session; update=updates)
    return "Unmuted thread $thread_id ($(length(email_ids)) emails)"
end

# ─── Tools vector ───

const JMAP_TOOLS = Agentif.AgentTool[
    EMAIL_SEARCH_TOOL,
    EMAIL_READ_TOOL,
    EMAIL_SEND_TOOL,
    EMAIL_REPLY_TOOL,
    EMAIL_FORWARD_TOOL,
    EMAIL_MOVE_TOOL,
    EMAIL_ARCHIVE_TOOL,
    EMAIL_TRASH_TOOL,
    EMAIL_FLAG_TOOL,
    EMAIL_MARK_READ_TOOL,
    LIST_MAILBOXES_TOOL,
    EMAIL_THREAD_TOOL,
    EMAIL_MUTE_THREAD_TOOL,
    EMAIL_UNMUTE_THREAD_TOOL,
]

end # module VoJMAPExt
