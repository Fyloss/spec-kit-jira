#!/usr/bin/env bash
# engine/drift.sh — Status-category-aware drift classification (US6, T071).
#
# PURE engine functions: zero Jira reads, zero writes, no sink/. Given a ticket's
# current status, that status's classification category (mapped / post-scope /
# halted / unknown, from lib/config.sh), the disk-inferred target status, the
# operator's phase-ordered status sequence, and the caller's --on-drift mode, this
# decides what the reconcile MUST do with the ticket's transition — and never
# silently overwrites Jira-side progress.
#
# The decision is a single canonical object the sink consumes:
#   { decision: "transition" | "withhold" | "halt",
#     content_writes: true | false,
#     warnings: [ ... ],          # named drift, human-readable
#     remediations: [ ... ] }     # only populated for a halt
#
#   transition  — the status transition may be emitted (aligned or an authorised
#                 forward/backward move).
#   withhold    — the transition is suppressed; content-only updates may still
#                 reconcile (content_writes stays true). Never a silent overwrite.
#   halt        — all writes to this ticket stop (content_writes false); the
#                 orphaned spec is surfaced with two remediations for a human.
#
# Rules (FR 031, FR 034, FR 035):
#   halted     -> halt, two remediations (archive the spec, or reopen the ticket).
#   unknown    -> withhold the transition, name the drift, suggest classifying it.
#   post-scope -> never treated as backward drift; but if the disk phase regressed
#                 (target precedes current in the order) the backward transition
#                 aborts by default and requires --on-drift=proceed (FR 035).
#   mapped     -> if the ticket advanced Jira-side beyond the target, withhold and
#                 warn (never silent overwrite, FR 031); --on-drift=proceed pulls
#                 it back. Otherwise transition normally.

[[ -n ${_JIRA_ENGINE_DRIFT:-} ]] && return 0
_JIRA_ENGINE_DRIFT=1

_drift_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_drift_dir}/../lib/output.sh"

# drift_evaluate <input-json> — classify one ticket's drift and decide its fate.
#   input: { current_status, current_category, target_status,
#            order:[status,...], on_drift:"abort"|"proceed" }
#   stdout: the canonical decision object described above.
# order is the operator's DISTINCT phase-ordered status sequence (from
# config_phase_status_targets, in phase order). A status absent from order has no
# comparable position, so no advance/regress is inferred for it (conservative:
# the transition proceeds only when the two positions are comparable).
drift_evaluate() {
  local input="$1"
  # kcov-excl-start — multi-line jq literal: kcov counts string continuation
  # lines as unhittable statements
  jq -n --argjson in "${input}" '
    ($in.current_status // "")   as $cur
    | ($in.current_category // "unknown") as $cat
    | ($in.target_status // "")  as $tgt
    | ($in.order // [])          as $order
    | (if ($in.on_drift // "abort") == "proceed" then "proceed" else "abort" end) as $onDrift
    | ($order | index($cur))     as $ci
    | ($order | index($tgt))     as $ti
    | (if $cat == "halted" then
         { decision:"halt", content_writes:false,
           warnings:[ "ticket status \"\($cur)\" is halted; all writes to this ticket are withheld until a human resolves it" ],
           remediations:[ "archive the specification", "reopen the ticket" ] }
       elif $cat == "unknown" then
         { decision:"withhold", content_writes:true,
           warnings:[ "status \"\($cur)\" is unclassified; its drift cannot be evaluated — run the config command to classify it, then reconcile" ],
           remediations:[] }
       elif $cat == "post-scope" then
         (if ($ci != null and $ti != null and $ti < $ci) then
            (if $onDrift == "proceed" then
               { decision:"transition", content_writes:true,
                 warnings:[ "ticket sits in post-scope status \"\($cur)\" but the specification regressed to \"\($tgt)\"; pulling it backward per --on-drift=proceed" ],
                 remediations:[] }
             else
               { decision:"withhold", content_writes:true,
                 warnings:[ "ticket sits in post-scope status \"\($cur)\" but the specification regressed to \"\($tgt)\"; the backward transition is withheld — pass --on-drift=proceed to pull it back" ],
                 remediations:[] }
             end)
          else
            { decision:"transition", content_writes:true, warnings:[], remediations:[] }
          end)
       else  # mapped
         (if ($ci != null and $ti != null and $ci > $ti) then
            (if $onDrift == "proceed" then
               { decision:"transition", content_writes:true,
                 warnings:[ "ticket advanced Jira-side to \"\($cur)\", beyond the specification'"'"'s \"\($tgt)\"; pulling it back per --on-drift=proceed" ],
                 remediations:[] }
             else
               { decision:"withhold", content_writes:true,
                 warnings:[ "ticket advanced Jira-side to \"\($cur)\", beyond the specification'"'"'s \"\($tgt)\"; the transition is withheld to avoid overwriting that progress (drift)" ],
                 remediations:[] }
             end)
          else
            { decision:"transition", content_writes:true, warnings:[], remediations:[] }
          end)
       end)
  ' | json_canonical
  # kcov-excl-stop
}
