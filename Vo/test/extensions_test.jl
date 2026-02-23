module ExtensionTests

using Test
using Agentif
using Mattermost
using MSTeams
using Signal
using Slack
using Vo

const HAS_GITHUB = try
    @eval using GitHub
    true
catch
    false
end

const HAS_JMAP = try
    @eval using JMAP
    true
catch
    false
end

if HAS_GITHUB
@testset "VoGitHubExt event mapping" begin
    ext = Base.get_extension(Vo, :VoGitHubExt)
    @test ext !== nothing

    source = ext.GitHubEventSource(; secret="test-secret", port=19876, app_id=12345, private_key_path="/tmp/fake.pem")
    @test source.app_id == 12345
    @test source.private_key_path == "/tmp/fake.pem"
    event_types = Vo.get_event_types(source)
    et_names = Set(et.name for et in event_types)

    # One event type per webhook kind
    @test "github_push" in et_names
    @test "github_fork" in et_names
    @test "github_ping" in et_names
    @test "github_pull_request" in et_names
    @test "github_issues" in et_names
    @test "github_issue_comment" in et_names
    @test "github_release" in et_names
    @test "github_workflow_run" in et_names
    @test "github_star" in et_names
    @test length(event_types) == length(ext.GITHUB_WEBHOOK_KINDS)

    # No default handlers (non-channel event source)
    @test isempty(Vo.get_event_handlers(source))
    @test isempty(Vo.get_channels(source))
    @test isempty(Vo.get_tools(source))

    # Event name is always per-kind (action is in event_content, not name)
    ev_push = ext.GitHubWebhookEvent("push", "", Dict{String,Any}("ref" => "refs/heads/main"), "owner/repo", "alice")
    @test Vo.get_name(ev_push) == "github_push"

    ev_pr = ext.GitHubWebhookEvent("pull_request", "opened",
        Dict{String,Any}("action" => "opened", "pull_request" => Dict{String,Any}(
            "title" => "Add feature", "body" => "Description here",
            "html_url" => "https://github.com/owner/repo/pull/42",
            "number" => 42, "base" => Dict("ref" => "main"), "head" => Dict("ref" => "feature"),
        )),
        "owner/repo", "bob")
    @test Vo.get_name(ev_pr) == "github_pull_request"

    # Session key for PR events groups by PR number
    @test Vo.get_session_key(ev_pr) == "github:owner/repo:pull_request:42"

    # Session key for issue events
    ev_issue = ext.GitHubWebhookEvent("issues", "opened",
        Dict{String,Any}("action" => "opened", "issue" => Dict{String,Any}(
            "title" => "Bug report", "number" => 7, "html_url" => "https://github.com/owner/repo/issues/7",
        )),
        "owner/repo", "carol")
    @test Vo.get_session_key(ev_issue) == "github:owner/repo:issue:7"

    # Session key for push events
    @test Vo.get_session_key(ev_push) == "github:owner/repo:push:refs/heads/main"

    # Event content formatting
    content_pr = Vo.event_content(ev_pr)
    @test occursin("owner/repo", content_pr)
    @test occursin("Add feature", content_pr)
    @test occursin("opened", content_pr)

    content_push = Vo.event_content(ev_push)
    @test occursin("push", content_push)
    @test occursin("refs/heads/main", content_push)

    # Push with commits
    ev_push_commits = ext.GitHubWebhookEvent("push", "",
        Dict{String,Any}(
            "ref" => "refs/heads/main",
            "commits" => [
                Dict{String,Any}("id" => "abc1234567890", "message" => "Fix bug"),
                Dict{String,Any}("id" => "def4567890123", "message" => "Update docs"),
            ],
        ),
        "owner/repo", "dave")
    content_commits = Vo.event_content(ev_push_commits)
    @test occursin("abc1234", content_commits)
    @test occursin("Fix bug", content_commits)
    @test occursin("Commits (2)", content_commits)

    # Issue comment event
    ev_comment = ext.GitHubWebhookEvent("issue_comment", "created",
        Dict{String,Any}("action" => "created",
            "comment" => Dict{String,Any}("body" => "LGTM!", "html_url" => "https://github.com/owner/repo/issues/7#issuecomment-1"),
            "issue" => Dict{String,Any}("title" => "Bug report", "number" => 7),
        ),
        "owner/repo", "eve")
    @test Vo.get_session_key(ev_comment) == "github:owner/repo:issue:7"
    content_comment = Vo.event_content(ev_comment)
    @test occursin("LGTM!", content_comment)
    @test occursin("Bug report", content_comment)

    # Generic event fallback
    ev_star = ext.GitHubWebhookEvent("star", "created", Dict{String,Any}("action" => "created"), "owner/repo", "fan")
    @test Vo.get_name(ev_star) == "github_star"
    content_star = Vo.event_content(ev_star)
    @test occursin("star", content_star)
    @test occursin("fan", content_star)
end
else
    @info "Skipping VoGitHubExt tests: GitHub package unavailable in test environment"
end

if HAS_JMAP
@testset "VoJMAPExt new email events" begin
    ext = Base.get_extension(Vo, :VoJMAPExt)
    @test ext !== nothing

    source = ext.FastmailEventSource(; token="test-token")
    assistant = Vo.AgentAssistant(":memory:";
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
    )

    session = JMAP.Session("https://example.invalid")
    session.mailAccountId = "acct-1"
    source._session = session
    source._inbox_mailbox_ids["acct-1"] = Set(["mb-inbox"])

    function drain_events!()
        while isready(assistant.event_queue)
            take!(assistant.event_queue)
        end
    end

    event_types = Vo.get_event_types(source)
    @test length(event_types) == 1
    @test event_types[1].name == "jmap_new_email"
    @test occursin("inbox", lowercase(event_types[1].description))

    original_email_changes_fn = ext.EMAIL_CHANGES_FN[]
    original_fetch_emails_fn = ext.FETCH_EMAILS_FN[]
    try
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> JMAP.ChangesResponse(
            accountId=account_id,
            oldState="E1",
            newState="E2",
            hasMoreChanges=false,
            created=["m1"],
            updated=String[],
            destroyed=String[],
        )
        ext.FETCH_EMAILS_FN[] = (_session, ids; account_id, properties) -> begin
            @test ids == ["m1"]
            @test account_id == "acct-1"
            @test "mailboxIds" in properties
            return JMAP.Email[
                JMAP.Email(
                    id="m1",
                    threadId="t1",
                    mailboxIds=Dict("mb-inbox" => true),
                    keywords=Dict{String,Bool}(),
                    from=[JMAP.EmailAddress(name="Alice", email="alice@example.com")],
                    subject="Hello",
                    receivedAt="2026-02-22T12:00:00Z",
                    preview="Test preview",
                ),
            ]
        end

        # First observation seeds baseline and emits nothing.
        sc_seed = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E1")))
        ext._handle_state_change!(source, assistant, sc_seed)
        @test source._states["acct-1"]["Email"] == "E1"
        @test !isready(assistant.event_queue)

        # Email created in inbox emits one high-level new-email event.
        sc_new = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E2")))
        ext._handle_state_change!(source, assistant, sc_new)
        @test isready(assistant.event_queue)
        ev = take!(assistant.event_queue)
        @test ev isa ext.JMAPNewEmailEvent
        @test Vo.get_name(ev) == "jmap_new_email"
        @test ev.email_id == "m1"
        @test ev.thread_id == "t1"
        @test ev.unread
        @test !ev.has_attachment
        @test occursin("new email arrived", lowercase(Vo.event_content(ev)))

        # Updates without creates do not emit events.
        drain_events!()
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> JMAP.ChangesResponse(
            accountId=account_id,
            oldState="E2",
            newState="E3",
            hasMoreChanges=false,
            created=String[],
            updated=["m1"],
            destroyed=String[],
        )
        sc_update = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E3")))
        ext._handle_state_change!(source, assistant, sc_update)
        @test source._states["acct-1"]["Email"] == "E3"
        @test !isready(assistant.event_queue)

        # Created email outside inbox is ignored.
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> JMAP.ChangesResponse(
            accountId=account_id,
            oldState="E3",
            newState="E4",
            hasMoreChanges=false,
            created=["m2"],
            updated=String[],
            destroyed=String[],
        )
        ext.FETCH_EMAILS_FN[] = (_session, ids; account_id, properties) -> begin
            @test ids == ["m2"]
            return JMAP.Email[
                JMAP.Email(
                    id="m2",
                    threadId="t2",
                    mailboxIds=Dict("mb-sent" => true),
                    keywords=Dict("\$seen" => true),
                    from=[JMAP.EmailAddress(name="Me", email="me@example.com")],
                    subject="Sent message",
                ),
            ]
        end
        sc_non_inbox = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E4")))
        ext._handle_state_change!(source, assistant, sc_non_inbox)
        @test source._states["acct-1"]["Email"] == "E4"
        @test !isready(assistant.event_queue)

        # If Email/changes fails, state still advances to avoid stale replay loops.
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> error("boom for $account_id")
        sc_error = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E5")))
        ext._handle_state_change!(source, assistant, sc_error)
        @test source._states["acct-1"]["Email"] == "E5"
        @test !isready(assistant.event_queue)
    finally
        ext.EMAIL_CHANGES_FN[] = original_email_changes_fn
        ext.FETCH_EMAILS_FN[] = original_fetch_emails_fn
    end

    close(assistant.db)
end
else
    @info "Skipping VoJMAPExt tests: JMAP package unavailable in test environment"
end

@testset "VoSlackExt event mapping" begin
    ext = Base.get_extension(Vo, :VoSlackExt)
    @test ext !== nothing

    source = ext.SlackEventSource(; app_token="xapp-test", bot_token="xoxb-test")
    event_types = Set(et.name for et in Vo.get_event_types(source))
    @test "slack_message" in event_types
    @test "slack_reaction" in event_types
    handlers = Vo.get_event_handlers(source)
    @test any(h -> h.id == "slack_message_default", handlers)
    @test any(h -> h.id == "slack_reaction_default", handlers)

    web_client = Slack.WebClient(; token="xoxb-test")
    channel_type_cache = Dict("C123" => "channel", "C555" => "group", "C999" => "group")

    msg = Slack.SlackMessageEvent(
        type="message",
        channel="C123",
        channel_type="channel",
        user="U123",
        text="hello",
        ts="1700000000.123",
    )
    msg_event = ext._extract_message_event(msg, web_client, "", "", nothing, nothing, channel_type_cache)
    @test msg_event !== nothing
    @test Vo.get_name(msg_event) == "slack_message"
    @test Agentif.channel_id(Vo.get_channel(msg_event)) == "slack:C123:1700000000.123"
    @test !msg_event.direct_ping
    @test Agentif.source_message_id(Vo.get_channel(msg_event)) == "1700000000.123"
    @test Vo.event_content(msg_event) == "[U123]: hello"

    private_msg = Slack.SlackMessageEvent(
        type="message",
        channel="C555",
        channel_type="private_channel",
        user="U555",
        text="private hello",
        ts="1700000000.777",
    )
    private_msg_event = ext._extract_message_event(private_msg, web_client, "", "", nothing, nothing, channel_type_cache)
    @test private_msg_event !== nothing
    @test Agentif.is_group(Vo.get_channel(private_msg_event))
    @test Agentif.is_private(Vo.get_channel(private_msg_event))

    mention = Slack.SlackAppMentionEvent(
        type="app_mention",
        channel="C123",
        user="U123",
        text="<@UBOT> hi",
        ts="1700000001.456",
    )
    mention_event = ext._extract_message_event(mention, web_client, "UBOT", "vo", nothing, nothing, channel_type_cache)
    @test mention_event !== nothing
    @test mention_event.direct_ping

    bot_msg = Slack.SlackMessageEvent(
        type="message",
        channel="C123",
        channel_type="channel",
        bot_id="B999",
        text="ignore me",
        ts="1700000002.789",
    )
    @test ext._extract_message_event(bot_msg, web_client, "", "", nothing, nothing, channel_type_cache) === nothing

    reaction_payload = Slack.JSON.Object(
        "type" => "reaction_added",
        "user" => "U234",
        "reaction" => "thumbsup",
        "item" => Slack.JSON.Object(
            "type" => "message",
            "channel" => "C123",
            "ts" => "1700000000.123",
        ),
    )
    reaction_event = ext._extract_reaction_event(reaction_payload, web_client, "", nothing, nothing, channel_type_cache)
    @test reaction_event !== nothing
    @test Vo.get_name(reaction_event) == "slack_reaction"
    @test occursin("thumbsup", Vo.event_content(reaction_event))
    @test !Agentif.is_private(Vo.get_channel(reaction_event))

    private_reaction_payload = Slack.JSON.Object(
        "type" => "reaction_added",
        "user" => "U333",
        "reaction" => "eyes",
        "item" => Slack.JSON.Object(
            "type" => "message",
            "channel" => "C999",
            "ts" => "1700000010.999",
        ),
    )
    private_reaction = ext._extract_reaction_event(private_reaction_payload, web_client, "", nothing, nothing, channel_type_cache)
    @test private_reaction !== nothing
    @test Agentif.is_group(Vo.get_channel(private_reaction))
    @test Agentif.is_private(Vo.get_channel(private_reaction))

    @test ext._channel_type_from_info(Dict("is_im" => true)) == "im"
    @test ext._channel_type_from_info(Dict("is_channel" => true, "is_private" => false)) == "channel"
    @test ext._channel_type_from_info(Dict("is_channel" => true, "is_private" => true)) == "group"
    @test ext._channel_type_from_info(Dict("is_mpim" => true)) == "mpim"
    @test ext._channel_type_from_info(Dict("is_group" => true)) == "group"
    @test ext._channel_type_from_info(nothing) === nothing

    # Streaming should be allowed for IM without recipient IDs, but not for channel/group.
    stream_im = ext.SlackChannel("D111", "1700000000.500", "", web_client, nothing, nothing, "", "", "im", nothing, nothing, "")
    Agentif.start_streaming(stream_im)
    @test stream_im.sm !== nothing
    @test stream_im.io === nothing

    stream_channel_missing_recipients = ext.SlackChannel("C111", "1700000000.600", "", web_client, nothing, nothing, "", "", "channel", nothing, nothing, "")
    Agentif.start_streaming(stream_channel_missing_recipients)
    @test stream_channel_missing_recipients.sm === nothing
    @test stream_channel_missing_recipients.io !== nothing

    # Outgoing message path should prefer markdown blocks and preserve markdown text.
    original_api_call_fn = ext.API_CALL_FN[]
    original_chat_post_message_fn = ext.CHAT_POST_MESSAGE_FN[]
    try
        api_calls = NamedTuple[]
        fallback_calls = NamedTuple[]
        ext.API_CALL_FN[] = function (_client, api_method; json=nothing, kwargs...)
            push!(api_calls, (api_method=String(api_method), json=json))
            return Dict{String, Any}("ok" => true, "channel" => json["channel"], "ts" => "1700000009.111")
        end
        ext.CHAT_POST_MESSAGE_FN[] = function (_client; channel, text=nothing, thread_ts=nothing, mrkdwn=nothing, parse=nothing, kwargs...)
            push!(fallback_calls, (
                channel=String(channel),
                text=text === nothing ? nothing : String(text),
                thread_ts=thread_ts === nothing ? nothing : String(thread_ts),
                mrkdwn=mrkdwn,
                parse=parse === nothing ? nothing : String(parse),
            ))
            return Dict{String, Any}("ok" => true, "channel" => String(channel), "ts" => "1700000010.222")
        end

        markdown = "# Heading\n- item\n```julia\nx = 1\n```"
        out_ch = ext.SlackChannel("C123", "", "", web_client, nothing, nothing, "", "", "channel", nothing, nothing, "")
        Agentif.send_message(out_ch, markdown)
        @test length(api_calls) == 1
        @test isempty(fallback_calls)
        @test api_calls[1].api_method == "chat.postMessage"
        @test api_calls[1].json["channel"] == "C123"
        @test api_calls[1].json["text"] == markdown
        @test api_calls[1].json["blocks"][1]["type"] == "markdown"
        @test api_calls[1].json["blocks"][1]["text"] == markdown
        @test out_ch.post_ts == "1700000009.111"
        @test Vo.get_followup_session_key(out_ch) == "slack:C123:1700000009.111"

        # If markdown blocks are rejected, fallback to classic mrkdwn text.
        ext.API_CALL_FN[] = function (client, _api_method; json=nothing, kwargs...)
            resp = Slack.SlackResponse(
                client,
                "POST",
                "https://slack.com/api/chat.postMessage",
                Dict{String,Any}(),
                Slack.JSON.Object("ok" => false, "error" => "invalid_blocks"),
                Dict{String,String}(),
                200,
            )
            throw(Slack.SlackApiError("invalid blocks", resp))
        end
        threaded_ch = ext.SlackChannel("C123", "1700000000.999", "", web_client, nothing, nothing, "", "", "channel", nothing, nothing, "")
        Agentif.send_message(threaded_ch, markdown)
        @test length(fallback_calls) == 1
        @test fallback_calls[1].channel == "C123"
        @test fallback_calls[1].thread_ts == "1700000000.999"
        @test fallback_calls[1].text == markdown
        @test fallback_calls[1].mrkdwn == true
        @test fallback_calls[1].parse == "none"
        @test threaded_ch.post_ts == "1700000010.222"
        @test Vo.get_followup_session_key(threaded_ch) == Agentif.channel_id(threaded_ch)
    finally
        ext.API_CALL_FN[] = original_api_call_fn
        ext.CHAT_POST_MESSAGE_FN[] = original_chat_post_message_fn
    end

    assistant = Vo.AgentAssistant(":memory:";
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
    )

    # Group non-mention message should enqueue; group prompt decides whether to stay silent.
    group_request = Slack.SocketModeRequest(
        type="events_api",
        envelope_id="env-1",
        payload=Slack.SlackEventsApiPayload(
            type="event_callback",
            event_id="evt-group-1",
            event=Slack.SlackMessageEvent(
                type="message",
                channel="C123",
                channel_type="channel",
                user="U123",
                text="hello everyone",
                ts="1700000003.111",
            ),
        ),
    )
    ext._handle_request(group_request, web_client, "", "", nothing, nothing, assistant, channel_type_cache)
    @test isready(assistant.event_queue)
    ev_group = take!(assistant.event_queue)
    @test ev_group isa ext.SlackMessageEvent
    @test !ev_group.direct_ping

    # app_mention callbacks are ignored to avoid duplicate processing.
    mention_request = Slack.SocketModeRequest(
        type="events_api",
        envelope_id="env-2",
        payload=Slack.SlackEventsApiPayload(
            type="event_callback",
            event_id="evt-mention-1",
            event=Slack.SlackAppMentionEvent(
                type="app_mention",
                channel="C123",
                user="U123",
                text="<@UBOT> hi",
                ts="1700000004.222",
            ),
        ),
    )
    ext._handle_request(mention_request, web_client, "UBOT", "", nothing, nothing, assistant, channel_type_cache)
    @test !isready(assistant.event_queue)

    # Mention text in a message event still triggers direct_ping.
    mention_message_request = Slack.SocketModeRequest(
        type="events_api",
        envelope_id="env-3",
        payload=Slack.SlackEventsApiPayload(
            type="event_callback",
            event_id="evt-message-mention-1",
            event=Slack.SlackMessageEvent(
                type="message",
                channel="C123",
                channel_type="channel",
                user="U123",
                text="<@UBOT> hi",
                ts="1700000005.333",
            ),
        ),
    )
    ext._handle_request(mention_message_request, web_client, "UBOT", "", nothing, nothing, assistant, channel_type_cache)
    @test isready(assistant.event_queue)
    ev = take!(assistant.event_queue)
    @test ev isa ext.SlackMessageEvent
    @test ev.direct_ping

    # Re-delivery is processable without event-id dedupe cache.
    ext._handle_request(mention_message_request, web_client, "UBOT", "", nothing, nothing, assistant, channel_type_cache)
    @test isready(assistant.event_queue)
    ev2 = take!(assistant.event_queue)
    @test ev2 isa ext.SlackMessageEvent

    close(assistant.db)
end

@testset "VoMattermostExt channel buffering" begin
    ext = Base.get_extension(Vo, :VoMattermostExt)
    @test ext !== nothing

    source = ext.MattermostEventSource()
    event_types = Set(et.name for et in Vo.get_event_types(source))
    @test "mattermost_message" in event_types
    @test "mattermost_reaction" in event_types
    handlers = Vo.get_event_handlers(source)
    @test any(h -> h.id == "mattermost_message_default", handlers)
    @test any(h -> h.id == "mattermost_reaction_default", handlers)

    client = Mattermost.Client("test-token", "https://example.invalid/api/v4/")
    ch = ext.MattermostChannel("chan-1", "root-1", "post-1", client, nothing, "user-1", "alice", "D", "Test Channel")

    @test Agentif.channel_id(ch) == "mattermost:chan-1:root-1"
    @test Agentif.source_message_id(ch) == "post-1"
    @test !Agentif.is_group(ch)
    @test Agentif.is_private(ch)
    user = Agentif.get_current_user(ch)
    @test user !== nothing
    @test user.id == "user-1"
    @test user.name == "alice"

    Agentif.start_streaming(ch)
    @test ch.io !== nothing
    Agentif.append_to_stream(ch, "Hello")
    Agentif.append_to_stream(ch, " world")
    Agentif.finish_streaming(ch)
    @test String(take!(ch.io)) == "Hello world"

    # Empty buffer on close should do nothing and clear channel state.
    ch.io = IOBuffer()
    Agentif.close_channel(ch)
    @test ch.io === nothing
end

@testset "VoSignalExt event mapping" begin
    ext = Base.get_extension(Vo, :VoSignalExt)
    @test ext !== nothing

    source = ext.SignalEventSource(; number="+15550000000", base_url="http://127.0.0.1:8080", auto_reconnect=false)
    event_types = Set(et.name for et in Vo.get_event_types(source))
    @test event_types == Set(["signal_message"])
    handlers = Vo.get_event_handlers(source)
    @test any(h -> h.id == "signal_message_default", handlers)

    client = Signal.Client("+15550000000", "http://127.0.0.1:8080")

    dm = Signal.DataMessage(message="hello signal", timestamp=Int64(1700000000000))
    envelope = Signal.Envelope(sourceNumber="+12223334444", sourceName="Alice", dataMessage=dm)
    msg_event = ext._envelope_to_message_event(envelope, client, "+15550000000")
    @test msg_event !== nothing
    @test Vo.get_name(msg_event) == "signal_message"
    @test Vo.event_content(msg_event) == "hello signal"
    ch = Vo.get_channel(msg_event)
    @test Agentif.channel_id(ch) == "signal:+12223334444"
    @test Agentif.source_message_id(ch) == "1700000000000"
    @test !Agentif.is_group(ch)
    @test Agentif.is_private(ch)
    tools = Agentif.create_channel_tools(ch)
    @test length(tools) == 1
    @test tools[1].name == "react_to_message"

    group_dm = Signal.DataMessage(
        message="group hello",
        timestamp=Int64(1700000001000),
        groupInfo=Signal.GroupInfo(groupId="abc123"),
    )
    group_envelope = Signal.Envelope(sourceNumber="+19998887777", sourceName="Bob", dataMessage=group_dm)
    group_event = ext._envelope_to_message_event(group_envelope, client, "+15550000000")
    @test group_event !== nothing
    group_channel = Vo.get_channel(group_event)
    @test startswith(group_channel.recipient, "group.")
    @test Agentif.is_group(group_channel)
    @test Vo.event_content(group_event) == "[Bob]: group hello"

    self_dm = Signal.DataMessage(message="self", timestamp=Int64(1700000002000))
    self_envelope = Signal.Envelope(sourceNumber="+15550000000", dataMessage=self_dm)
    @test ext._envelope_to_message_event(self_envelope, client, "+15550000000") === nothing
end

@testset "VoMSTeamsExt event mapping" begin
    ext = Base.get_extension(Vo, :VoMSTeamsExt)
    @test ext !== nothing

    source = ext.MSTeamsEventSource(; app_id="app-id", app_password="secret")
    event_types = Set(et.name for et in Vo.get_event_types(source))
    @test "msteams_message" in event_types
    @test "msteams_reaction" in event_types
    handlers = Vo.get_event_handlers(source)
    @test any(h -> h.id == "msteams_message_default", handlers)
    @test any(h -> h.id == "msteams_reaction_default", handlers)

    client = MSTeams.BotClient(; app_id="app-id", app_password="secret")

    message_activity = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-1",
        "text" => "hello teams",
        "from" => Dict("id" => "user-1", "name" => "Alice"),
        "recipient" => Dict("id" => "bot-1", "name" => "Vo"),
        "conversation" => Dict("id" => "conv-1", "conversationType" => "channel"),
    )
    message_events = ext._activity_to_events(message_activity, client)
    @test length(message_events) == 1
    msg_event = only(message_events)
    @test msg_event isa ext.MSTeamsMessageEvent
    msg_channel = Vo.get_channel(msg_event)
    @test Agentif.channel_id(msg_channel) == "msteams:conv-1"
    @test Agentif.is_group(msg_channel)
    @test !Agentif.is_private(msg_channel)
    @test Agentif.source_message_id(msg_channel) == "activity-1"
    @test Vo.event_content(msg_event) == "[Alice]: hello teams"

    dm_activity = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-2",
        "text" => "dm ping",
        "from" => Dict("id" => "user-2", "name" => "Dana"),
        "recipient" => Dict("id" => "bot-1", "name" => "Vo"),
        "conversation" => Dict("id" => "conv-2", "conversationType" => "personal"),
    )
    dm_event = only(ext._activity_to_events(dm_activity, client))
    @test dm_event.direct_ping

    mention_activity = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-3",
        "text" => "<at>Vo</at> hello",
        "from" => Dict("id" => "user-3", "name" => "Morgan"),
        "recipient" => Dict("id" => "bot-1", "name" => "Vo"),
        "conversation" => Dict("id" => "conv-3", "conversationType" => "channel"),
        "entities" => [Dict(
            "type" => "mention",
            "mentioned" => Dict("id" => "bot-1"),
        )],
    )
    mention_event = only(ext._activity_to_events(mention_activity, client))
    @test mention_event.direct_ping

    reaction_activity = Dict{String, Any}(
        "type" => "messageReaction",
        "id" => "reaction-1",
        "replyToId" => "activity-1",
        "from" => Dict("id" => "user-4", "name" => "Riley"),
        "conversation" => Dict("id" => "conv-1", "conversationType" => "channel"),
        "reactionsAdded" => [Dict("type" => "like")],
        "reactionsRemoved" => [Dict("type" => "sad")],
    )
    reaction_events = ext._activity_to_events(reaction_activity, client)
    @test length(reaction_events) == 2
    @test count(ev -> ev isa ext.MSTeamsReactionEvent, reaction_events) == 2
    @test any(ev -> ev.action == "added" && ev.reaction == "like", reaction_events)
    @test any(ev -> ev.action == "removed" && ev.reaction == "sad", reaction_events)

    bot_message = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-4",
        "text" => "bot text",
        "from" => Dict("id" => "bot-1", "name" => "Vo"),
        "recipient" => Dict("id" => "bot-1", "name" => "Vo"),
        "conversation" => Dict("id" => "conv-4", "conversationType" => "channel"),
    )
    @test isempty(ext._activity_to_events(bot_message, client))
end

end # module ExtensionTests
