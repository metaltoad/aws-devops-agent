#!/usr/bin/env bash
#
# Associates the already-registered Slack workspace ("Metal Toad") with the MT AWS
# DevOps Agent, binding a private Slack channel for bidirectional communication.
#
# IMPORTANT: a Slack service is already registered on this account (serviceId
# 9a197d96-f4bc-43cc-a5f0-db0cb2c8377f, workspaceId T025YJAB8, "Metal Toad"), created
# 2026-03-30. It was never associated with this Agent Space, so before this ticket the
# agent could not post to or receive from any Slack channel. This script does not
# re-register Slack (RegisterService is a one-time OAuth flow done in the console/Slack
# authorization page, not scriptable); it only associates the existing registration
# with a channel.
#
# Bidirectional communication (mention the agent, get a threaded reply) only works on
# PRIVATE Slack channels -- AWS enforces this, not this script. Public channels get
# one-way notifications only, regardless of the bidirectional config sent here.
#
# Bidirectional mode requires an IAM role that AWS DevOps Agent assumes to exchange
# Slack messages. That role does not come from AssociateService/UpdateAssociation --
# it must already exist. This repo provisions it via CloudFormation:
#   cloudformation/slack-devops-agent-role.yaml -> stack devops-agent-slack-channel-access
# Deploy that stack first (or pass --role-arn to point at a different role) before
# running this script with --apply.
#
# Usage:
#   ./setup-slack-devops-agent.sh assoc --channel-id C0C3P4HMD34                # dry run
#   ./setup-slack-devops-agent.sh assoc --channel-id C0C3P4HMD34 --apply
#   ./setup-slack-devops-agent.sh assoc --channel-id C0C3P4HMD34 --no-bidirectional --apply
#   ./setup-slack-devops-agent.sh verify
#
set -euo pipefail

# --------------------------------------------------------------------------- config

AGENT_SPACE_ID="${AGENT_SPACE_ID:-7002ac92-5fc8-4222-b661-95fe42548d80}"
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-831442996354}"
PROFILE="${AWS_PROFILE:-mt-media}"
REGION="${AWS_REGION:-us-east-1}"

# The Slack service registered against this account. Discovered via 'verify' /
# 'aws devops-agent list-services'. This script only associates it; it does not
# register a new one.
SLACK_SERVICE_ID="${SLACK_SERVICE_ID:-9a197d96-f4bc-43cc-a5f0-db0cb2c8377f}"
SLACK_WORKSPACE_ID="${SLACK_WORKSPACE_ID:-T025YJAB8}"
SLACK_WORKSPACE_NAME="${SLACK_WORKSPACE_NAME:-Metal Toad}"

# Role AWS DevOps Agent assumes for bidirectional Slack access. Defaults to the role
# provisioned by cloudformation/slack-devops-agent-role.yaml.
DEFAULT_ROLE_ARN="arn:aws:iam::${EXPECTED_ACCOUNT}:role/devops-agent-slack-channel-access-role"
ROLE_ARN="${SLACK_BIDIRECTIONAL_ROLE_ARN:-$DEFAULT_ROLE_ARN}"

MIN_CLI="2.34.20"

# --------------------------------------------------------------------------- helpers

ok()   { printf '\xe2\x9c\x93 %s\n' "$*"; }
warn() { printf '\xe2\x9a\xa0 %s\n' "$*" >&2; }
fail() { printf '\xe2\x9c\x97 %s\n' "$*" >&2; exit 1; }

WORKDIR=""
cleanup() {
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR"
  fi
  return 0
}
trap cleanup EXIT

mk_workdir() {
  WORKDIR="$(mktemp -d)"
  chmod 700 "$WORKDIR"
}

version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

preflight() {
  command -v aws >/dev/null 2>&1 || fail "aws CLI not found on PATH"
  command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"

  local ver
  ver="$(aws --version 2>&1 | sed -n 's|^aws-cli/\([0-9.]*\).*|\1|p')"
  [[ -n "$ver" ]] || fail "could not parse the aws CLI version"

  if ! version_ge "$ver" "$MIN_CLI"; then
    fail "aws CLI $ver is too old for the devops-agent service model; need >= $MIN_CLI."
  fi
  ok "aws CLI $ver (>= $MIN_CLI)"

  aws devops-agent help >/dev/null 2>&1 \
    || fail "this aws CLI has no 'devops-agent' service; upgrade the CLI"

  local acct
  acct="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null)" \
    || fail "cannot authenticate with profile '$PROFILE'. Try: aws sso login --sso-session MetalToad"
  [[ "$acct" == "$EXPECTED_ACCOUNT" ]] \
    || fail "profile '$PROFILE' resolves to account $acct, expected $EXPECTED_ACCOUNT"
  ok "authenticated against $acct via profile '$PROFILE'"
}

awsda() {
  aws devops-agent "$@" --profile "$PROFILE" --region "$REGION"
}

py() { python3 "$@"; }

# Echoes the associationId for a service on this agent space, or nothing if unassociated.
find_association_for_service() {
  awsda list-associations --agent-space-id "$AGENT_SPACE_ID" --output json 2>/dev/null \
    | py -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)
for a in (d.get("associations") or []):
    if a.get("serviceId") == want:
        print(a.get("associationId", ""))
        break
' "$1"
}

check_elevated_actions() {
  local elevated
  elevated="$(awsda get-agent-space --agent-space-id "$AGENT_SPACE_ID" \
    --query 'agentSpace.preferences.elevatedActionsEnabled' --output text 2>/dev/null || echo "unknown")"

  if [[ "$elevated" != "True" && "$elevated" != "true" ]]; then
    warn "directed actions are not enabled on this agent space (elevatedActionsEnabled=$elevated)."
    warn "Slack notifications and mention/reply still work regardless -- this flag only gates"
    warn "MUTATIVE tool calls (e.g. the Jira write tools), not the chat channel itself."
  else
    ok "directed actions enabled on the agent space"
  fi
}

check_role_exists() {
  local arn="$1"
  local name="${arn##*/}"
  aws iam get-role --role-name "$name" --profile "$PROFILE" >/dev/null 2>&1 \
    || fail "IAM role '$name' not found in this account. Deploy
  cloudformation/slack-devops-agent-role.yaml first:
    aws cloudformation deploy --template-file cloudformation/slack-devops-agent-role.yaml \\
      --stack-name devops-agent-slack-channel-access --capabilities CAPABILITY_NAMED_IAM \\
      --profile $PROFILE --region $REGION
  Or pass --role-arn / SLACK_BIDIRECTIONAL_ROLE_ARN to use a different, existing role."
  ok "IAM role exists: $arn"
}

# ------------------------------------------------------------------------------ assoc

phase_assoc() {
  local apply="$1" channel_id="$2" bidirectional="$3"

  [[ -n "$channel_id" ]] || fail "--channel-id is required"
  [[ "$channel_id" =~ ^[CGD][A-Z0-9]+$ ]] \
    || fail "channel id '$channel_id' does not look like a Slack channel ID (expected [CGD][A-Z0-9]+)"

  mk_workdir
  local body="$WORKDIR/associate.json"

  local existing_assoc
  existing_assoc="$(find_association_for_service "$SLACK_SERVICE_ID")"
  if [[ -n "$existing_assoc" ]]; then
    ok "Slack service already associated as $existing_assoc -- this will update it in place"
  else
    ok "no existing Slack association on this agent space -- this will create one"
  fi

  if [[ "$bidirectional" == "true" ]]; then
    check_role_exists "$ROLE_ARN"
  fi

  AGENT_SPACE_ID="$AGENT_SPACE_ID" \
  SERVICE_ID="$SLACK_SERVICE_ID" \
  WORKSPACE_ID="$SLACK_WORKSPACE_ID" \
  WORKSPACE_NAME="$SLACK_WORKSPACE_NAME" \
  CHANNEL_ID="$channel_id" \
  ROLE_ARN="$ROLE_ARN" \
  BIDIRECTIONAL="$bidirectional" \
  ASSOCIATION_ID="$existing_assoc" \
  py - "$body" <<'PY'
import json, os, sys

slack_cfg = {
    "workspaceId": os.environ["WORKSPACE_ID"],
    "workspaceName": os.environ["WORKSPACE_NAME"],
    "transmissionTarget": {
        "opsOncallTarget": {
            "channelId": os.environ["CHANNEL_ID"],
        }
    },
}

if os.environ["BIDIRECTIONAL"] == "true":
    slack_cfg["bidirectional"] = {
        "roleArn": os.environ["ROLE_ARN"],
        "enabled": True,
    }

cfg = {"slack": slack_cfg}

aid = os.environ.get("ASSOCIATION_ID", "")
if aid:
    req = {"agentSpaceId": os.environ["AGENT_SPACE_ID"], "associationId": aid, "configuration": cfg}
else:
    req = {"agentSpaceId": os.environ["AGENT_SPACE_ID"], "serviceId": os.environ["SERVICE_ID"],
           "configuration": cfg}

with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(req, fh, indent=2)
PY

  echo "Request body:"
  cat "$body"
  echo

  if [[ "$apply" != "true" ]]; then
    warn "dry run, nothing associated. Re-run with --apply to associate."
    return 0
  fi

  check_elevated_actions

  local verb="associate-service"
  [[ -n "$existing_assoc" ]] && verb="update-association"

  ok "running $verb for Slack service $SLACK_SERVICE_ID on agent space $AGENT_SPACE_ID"
  local out="$WORKDIR/associate-out.json"
  awsda "$verb" --cli-input-json "file://$body" >"$out" \
    || fail "$verb failed. Common causes:
    - channel '$channel_id' is public and --bidirectional was requested: bidirectional
      communication is only supported on private Slack channels
    - the AWS DevOps Agent Slack app has not been invited into the channel yet
      (in Slack: /invite @AWS DevOps Agent - <Region>)
    - the role ARN is not assumable by aidevops.amazonaws.com for this agent space
      (check the trust policy's SourceArn condition)"

  py -c '
import json
d = json.load(open("'"$out"'", encoding="utf-8"))
assoc = d.get("association", d)
print("  associationId: " + str(assoc.get("associationId", "?")))
'
  ok "associated"
  echo
  echo "Next: in Slack, in channel $channel_id, send as a new top-level message:"
  echo "  @AWS DevOps Agent - US East (N. Virginia) setup"
  echo "Then, once confirmed, test with:"
  echo "  @AWS DevOps Agent - US East (N. Virginia) What can you do?"
}

# ----------------------------------------------------------------------------- verify

phase_verify() {
  ok "registered services (slack):"
  awsda list-services --query "services[?serviceType=='slack']" --output json

  echo
  local assoc
  assoc="$(find_association_for_service "$SLACK_SERVICE_ID")"
  if [[ -z "$assoc" ]]; then
    warn "no association between this agent space and serviceId $SLACK_SERVICE_ID"
    return 0
  fi
  ok "association $assoc:"
  awsda get-association --agent-space-id "$AGENT_SPACE_ID" --association-id "$assoc" --output json

  echo
  check_elevated_actions
}

# --------------------------------------------------------------------------------- cli

CMD="${1:-}"; shift || true
APPLY="false"
CHANNEL_ID=""
BIDIRECTIONAL="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --channel-id) CHANNEL_ID="$2"; shift 2 ;;
    --role-arn) ROLE_ARN="$2"; shift 2 ;;
    --no-bidirectional) BIDIRECTIONAL="false"; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

preflight

case "$CMD" in
  assoc)   phase_assoc "$APPLY" "$CHANNEL_ID" "$BIDIRECTIONAL" ;;
  verify)  phase_verify ;;
  *) fail "usage: $0 {assoc|verify} [--channel-id <id>] [--apply] [--no-bidirectional] [--role-arn <arn>]" ;;
esac
