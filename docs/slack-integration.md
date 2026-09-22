# Slack integration for AWS DevOps Agent

DEVOPS-3059

Connects the MT AWS DevOps Agent to a private Slack channel with bidirectional
communication: the agent posts notifications, and operators can mention it to
start a conversation and get a threaded reply.

| | |
|---|---|
| Agent space | `7002ac92-5fc8-4222-b661-95fe42548d80` (MetalToad Corp) |
| Account | `831442996354` (`mt-media`) |
| Region | `us-east-1` |
| Slack workspace | `Metal Toad`, `teamId T025YJAB8` |
| Slack service registration | `serviceId 9a197d96-f4bc-43cc-a5f0-db0cb2c8377f` (registered 2026-03-30, pre-existing) |
| Slack channel | `C0C3P4HMD34` (private) |
| Association | `0d547fb1-605a-4e83-b82b-9b74947dba94` |
| Bidirectional role | `arn:aws:iam::831442996354:role/devops-agent-slack-channel-access-role` |
| IAM role stack | `cloudformation/slack-devops-agent-role.yaml` -> stack `devops-agent-slack-channel-access` |
| Setup script | `scripts/setup-slack-devops-agent.sh` |

## Status against the acceptance criteria

| AC | Status |
|---|---|
| Slack app or integration is configured | **Done** — workspace registered, channel associated |
| Required permissions/scopes are reviewed and approved | **Partial** — AWS IAM side reviewed and proven to work end-to-end; Slack OAuth scopes not reviewed, no sign-off recorded |
| Agent can receive messages or commands from Slack | **Done** — verified in `C0C3P4HMD34`, 2026-09-22 |
| Agent can post responses to the appropriate Slack channel | **Done** — verified both conversationally and via unprompted investigation notifications, 2026-09-22 |
| Test interaction is completed successfully | **Done** — see [Verifying it works](#verifying-it-works) |

### What is genuinely not finished

**Slack OAuth scopes are unreviewed.** The AWS-side permissions (the bidirectional IAM
role and `AIDevOpsChannelAccessPolicy`) were reviewed and are now proven correct by two
separate live tests (conversational reply, and unprompted notification delivery — see
[Verifying it works](#verifying-it-works)). The Slack app's own OAuth scopes were
**not** reviewed — that grant was made on 2026-03-30, predates this ticket, and is not
readable from any AWS API (`list-services` exposes only `teamId` and `teamName`).
Closing this AC requires someone with Slack admin access to enumerate the granted scopes
(Slack admin -> Manage apps -> AWS DevOps Agent -> Permissions) and a named person to
approve them.

`opsSRETarget` (the SRE Agent / Ops1.5 destination) is also not configured — only
`opsOncallTarget`. It is optional, and no requirement here asked for it, but it means
SRE-agent output has no Slack destination.

## Why this needed a private channel

AWS DevOps Agent only supports bidirectional communication (mention the agent, get a
threaded reply) on **private** Slack channels. Public channels get one-way
notifications only — the agent can post into them, but it will never see or respond to
a message there, regardless of any configuration on the AWS side.

This ticket's ACs ("receive messages or commands," "post responses," a completed "test
interaction") only make sense with bidirectional mode, so the integration is built
against a private channel (`C0C3P4HMD34`). A public channel was considered and rejected
for this reason during setup.

## How it fits together

Two independent things had to exist before the channel could be associated:

**Account-level Slack registration** (`RegisterService`, one-time OAuth). Already
existed in this account before this ticket — `serviceId
9a197d96-f4bc-43cc-a5f0-db0cb2c8377f`, workspace `Metal Toad` (`T025YJAB8`), created
2026-03-30. Registration happens through Slack's own authorization page (the "Allow"
consent screen), which is not scriptable — there is no CLI verb that performs an OAuth
consent flow. This integration reuses that existing registration; it does not
re-register Slack.

**A prior draft of the Jira integration doc** noted "already... a Slack integration" on
this Agent Space. That was imprecise: the workspace OAuth grant existed, but
`list-associations` showed **no association** between that Slack service and this Agent
Space before this ticket — so the agent could not post to or receive from any channel.
This ticket is what actually connects the two. (See the top-level repo `docs/` for the
Jira integration writeup; that correction is noted there too.)

**Agent-space association** (`AssociateService`). Binds the registered `serviceId` to
this Agent Space, names the target channel, and — for bidirectional mode — supplies the
IAM role the agent assumes to exchange messages. This is where notifications actually
start flowing and where bidirectional mode is turned on.

### Why the IAM role is CloudFormation but the association is a script

Same asymmetry as the Jira integration, for a related reason.

`AWS::DevOpsAgent::Association`'s `SlackConfiguration` CloudFormation property type
exposes only `TransmissionTarget`, `WorkspaceId`, `WorkspaceName` — it has **no
`Bidirectional` property**. CloudFormation can express the notification-only half of a
Slack association, but not the bidirectional half this ticket needs. So, as with Jira's
missing `ToolDetails`, the association itself goes through the API/CLI.

The IAM role is a plain `AWS::IAM::Role` with no DevOps-Agent-specific CloudFormation
gap, so it lives in CloudFormation (`cloudformation/slack-devops-agent-role.yaml`) like
the rest of this repo's IaC, rather than being created ad hoc by a script.

## The bidirectional role's trust policy: sts:TagSession is required

This is the one non-obvious requirement, worth stating plainly because it fails with a
specific but easy-to-miss error.

AWS DevOps Agent's console can auto-create the bidirectional role for you. Building it
by hand in CloudFormation instead, the natural trust policy mirrors the pattern already
used elsewhere in this repo (see `stackset.yaml`'s `MT_Devops_Agent` role):
`aidevops.amazonaws.com` granted `sts:AssumeRole`, scoped by `aws:SourceAccount` and
`aws:SourceArn` (the agent space ARN).

That is **not sufficient** for the Slack bidirectional role. `AssociateService` rejects
it:

```
ValidationException: The bidirectional roleArn could not be validated. Ensure the
role exists in the Agent Space account, trusts the aidevops.amazonaws.com service
principal with SourceAccount and SourceArn conditions scoped to this Agent Space,
and allows sts:AssumeRole and sts:TagSession (see the AIDevOpsChannelAccessRoleTemplate).
```

The trust policy must grant **both** `sts:AssumeRole` and `sts:TagSession` to
`aidevops.amazonaws.com`. `sts:TagSession` is what lets DevOps Agent attach a session
tag identifying which Slack message/thread triggered the assumed-role session — needed
because, unlike the AWS-account investigation role, a single bidirectional role can
service many concurrent Slack conversations and the resulting CloudTrail events need to
be attributable to a specific interaction.

Confirmed empirically against this account: the role deployed with only
`sts:AssumeRole` was rejected with the error above; adding `sts:TagSession` and
redeploying fixed it. `cloudformation/slack-devops-agent-role.yaml` grants both from the
start. AWS does not appear to publish the exact `AIDevOpsChannelAccessRoleTemplate`
trust policy text anywhere in its docs, so this is the record of what it actually
requires.

```yaml
AssumeRolePolicyDocument:
  Version: "2012-10-17"
  Statement:
    - Effect: Allow
      Principal:
        Service: aidevops.amazonaws.com
      Action:
        - sts:AssumeRole
        - sts:TagSession
      Condition:
        StringEquals:
          aws:SourceAccount: !Ref AWS::AccountId
        ArnLike:
          aws:SourceArn: !Sub arn:aws:aidevops:${AWS::Region}:${AWS::AccountId}:agentspace/${AgentSpaceId}
```

## Permission boundaries

### 1. Slack workspace OAuth grant

The registered Slack service authenticates as whatever the original "Allow" consent
granted. That grant predates this ticket and was not reviewed as part of it — only the
channel association and the bidirectional IAM role are new here. If the OAuth scopes
ever need auditing, that is a Slack-app-management question (Slack admin ->
Apps -> AWS DevOps Agent), not something visible from the AWS side.

### 2. Channel-level access

The association only names one channel (`C0C3P4HMD34`). The agent has no reach into any
other Slack channel, public or private, in this workspace — Slack's own app-installation
model means the bot can only act in channels it has been explicitly invited into, and
this integration invited it into exactly one.

### 3. Bidirectional IAM role

`devops-agent-slack-channel-access-role` carries exactly one managed policy,
`AIDevOpsChannelAccessPolicy`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowChatActions",
      "Effect": "Allow",
      "Action": ["aidevops:CreateChat", "aidevops:SendMessage"],
      "Resource": "arn:aws:aidevops:*:*:agentspace/${aws:PrincipalTag/AgentSpaceId}",
      "Condition": {
        "StringEquals": {"aws:ResourceAccount": "${aws:PrincipalAccount}"}
      }
    }
  ]
}
```

This grants nothing beyond starting/continuing a chat against this Agent Space. It has
**no AWS resource access** — investigating and acting on AWS resources still goes through
the separate `MT_Devops_Agent` / `DevOpsAgentRole-AgentSpace-*` roles. A compromised
Slack-side credential could not use this role to touch EC2, IAM, S3, etc.

The role's trust policy additionally scopes *who* can assume it to `aidevops.amazonaws.com`
acting specifically on behalf of this Agent Space (`SourceArn` condition), so it cannot be
assumed by, or on behalf of, a different Agent Space in this account.

### 4. Directed actions (elevatedActionsEnabled)

Unrelated to whether Slack chat works, but worth restating since the Jira doc covers the
same flag: `elevatedActionsEnabled` on this Agent Space is currently `false` (unchanged
by this ticket). That only gates MUTATIVE tool calls, such as the Jira write tools — it
does not block Slack notifications or bidirectional replies. Asking the agent something
in Slack that only requires read-only investigation works today; asking it to perform a
mutating action will hit the same approval/elevation gate documented in
`docs/atlassian-jira-integration.md`, regardless of whether the request came from Slack
or the web app.

## Credential lifecycle

- The Slack OAuth grant is managed on Slack's side (Slack admin -> Apps). Revoking the
  app there breaks the integration immediately; no AWS-side action is needed to
  propagate that.
- Rotating or removing the bidirectional role only affects new conversations; the
  console/CLI documents no separate credential to rotate for the Slack side beyond the
  IAM role itself, which is managed the normal IAM way (this stack, or manually).
- Deregistering the Slack service or deleting the association removes the agent's access
  to the channel; deleting the CFN stack removes the IAM role and breaks bidirectional
  mode until it is redeployed and re-associated.

## Verifying it works

AWS-side state was confirmed via `get-association`:

```
associationId: 0d547fb1-605a-4e83-b82b-9b74947dba94
configuration.slack.transmissionTarget.opsOncallTarget.channelId: C0C3P4HMD34
configuration.slack.bidirectional.enabled: true
configuration.slack.bidirectional.roleArn: arn:aws:iam::831442996354:role/devops-agent-slack-channel-access-role
```

That is not sufficient evidence the integration actually works end to end — same caveat
as the Jira integration's tool names: a valid-looking association is not proof of a
working channel binding. It has to be exercised from Slack.

**Step 1 — bind the channel (one-time, per channel).** In the private channel
(`C0C3P4HMD34`), send this exact message as a new top-level message:

```
@AWS DevOps Agent - US East (N. Virginia) setup
```

Expect a confirmation reply from the app. If the channel has multiple eligible Agent
Space associations, expect a picker instead — select `MetalToad Corp`.

**Step 2 — test interaction.** In the same channel, mention the app again with a real
question:

```
@AWS DevOps Agent - US East (N. Virginia) What can you do?
```

Expect a reply in a thread under that message. Follow-up questions in the same thread
should also get replies without needing to re-mention the app for every message (mention
is required on each *top-level* message per AWS's docs, but not for follow-ups within an
already-open thread — confirm this behavior when testing, since it is the detail most
likely to surprise a first-time user).

Both steps have to happen inside Slack; there is no CLI equivalent.

**Verified 2026-09-22** — Maria Cecylia mentioned the app in `C0C3P4HMD34`:

```
@AWS DevOps Agent - US East (N. Virginia) what can you do?
```

and the agent replied in a thread with its capabilities menu (Investigations,
Infrastructure & resources, Recommendations, Release Manager), noting it ran one tool
call to produce the response. This confirms the **conversational** path works end to end
in the associated private channel: the agent receives a mention and posts a reply.

It does **not**, by itself, confirm notification delivery — the `opsOncallTarget` path
that pushes investigation findings into the channel is a separate code path. That was
verified next.

### Notification delivery — verified 2026-09-22

A deliberate test investigation was created to exercise the path a real incident would
use, since none of the 4 pre-existing `INVESTIGATION` tasks (all completed between
2026-02-26 and 2026-03-31, before this association existed on 2026-09-22 17:08 UTC) had
ever run with a Slack channel configured:

```bash
aws devops-agent create-backlog-task \
  --agent-space-id 7002ac92-5fc8-4222-b661-95fe42548d80 \
  --task-type INVESTIGATION \
  --title "DEVOPS-3059 test: verify Slack notification delivery" \
  --description "..." \
  --priority MINIMAL \
  --profile mt-media --region us-east-1
```

Task `d9d8e97c-a90a-43c9-ab0c-a7e5d8368a2b` (execution
`exe-ops1-204457c4-98c6-4d30-8df2-a21eada222e7`) ran and reached `COMPLETED` at
2026-09-22T17:35:03Z, with no one interacting with it from Slack. In `C0C3P4HMD34`, the
agent posted, unprompted:

- 2:32 PM — "Investigation started: DEVOPS-3059 test: verify Slack notification delivery"
- 2:33 PM — an observation with a verification token (`DEVOPS-3059-DELIVERY-CHECK-1790098367`)
  and timestamp (`2026-09-22T17:32:47Z`) embedded specifically so the Slack message could
  be matched back to this exact investigation run
- 2:35 PM — the full investigation results

The token and timestamp in the Slack messages matched the investigation record exactly.
This confirms the `opsOncallTarget → C0C3P4HMD34` push notification path works
end-to-end: an investigation completing on this Agent Space reaches the Slack channel
with no operator action required, which is the capability the ticket's Description asks
for ("support collaboration during incident investigation scenarios").

Worth noting for anyone reading the investigation's own write-up: the investigation
agent itself reported (correctly) that it has no Slack tool and cannot self-verify
delivery — Slack delivery is performed by a downstream notification layer outside the
investigation agent's own tool access. That is expected; it is why this had to be
confirmed by checking Slack directly rather than trusting the investigation record
alone.

This mirrors a gap the Jira integration doc flagged and left open — its EventBridge
callback was never exercised against a real investigation either. This ticket's test
task is what closed that gap for Slack; the same approach (a deliberate low-priority
`INVESTIGATION` backlog task) would close it for Jira too, if desired as follow-up.

## Redeploying the IAM role

```bash
aws cloudformation deploy \
  --template-file cloudformation/slack-devops-agent-role.yaml \
  --stack-name devops-agent-slack-channel-access \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 --profile mt-media
```

## Redoing or extending the association

```bash
cd scripts

# Dry run: prints the exact AssociateService/UpdateAssociation body.
./setup-slack-devops-agent.sh assoc --channel-id C0C3P4HMD34

# Apply.
./setup-slack-devops-agent.sh assoc --channel-id C0C3P4HMD34 --apply

# One-way notifications only, no bidirectional role needed.
./setup-slack-devops-agent.sh assoc --channel-id <other-channel-id> --no-bidirectional --apply

# Confirm current state.
./setup-slack-devops-agent.sh verify
```

Re-running `assoc` against a channel that is already associated updates that
association in place (`UpdateAssociation`) rather than creating a second one — the
script detects the existing association by `serviceId` first.

## Files

- `cloudformation/slack-devops-agent-role.yaml` — IAM role for bidirectional Slack
  access, deployed as stack `devops-agent-slack-channel-access`.
- `scripts/setup-slack-devops-agent.sh` — associates the Slack service with this Agent
  Space and a chosen channel; dry-run by default.

## References

- [Connecting Slack (AWS DevOps Agent user guide)](https://docs.aws.amazon.com/devopsagent/latest/userguide/connecting-to-ticketing-and-chat-connecting-slack.html)
- [SlackConfiguration (API reference)](https://docs.aws.amazon.com/devopsagent/latest/APIReference/API_SlackConfiguration.html)
- [SlackTransmissionTarget (API reference)](https://docs.aws.amazon.com/devopsagent/latest/APIReference/API_SlackTransmissionTarget.html)
- [AIDevOpsChannelAccessPolicy (AWS managed policy reference)](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AIDevOpsChannelAccessPolicy.html)
- [Working with directed actions](https://docs.aws.amazon.com/devopsagent/latest/userguide/working-with-devops-agent-working-with-directed-actions.html)
