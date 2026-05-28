"""dump-recent-sessions.py — INSIDE the container, used by the reviewer agent.

Usage: python3 /app/dump-recent-sessions.py [days=7]

Dumps the current sessions of all agents as JSON to stdout. Decodes msgpack,
strips internal fields, keeps role + content (text + tool_use names + brief
tool_result text). Limited to last N days of messages per agent.

The reviewer parses this output to evaluate Leandro's behavior.

Note: openfang's sessions table keeps ONE active session per agent (reused),
so "recent activity" = the tail of the messages list. We don't have
per-message timestamps inside msgpack (just session.updated_at), so we keep
the last K messages per agent based on a rough budget (50 messages/agent =
plenty for a week of typical activity, well under context budget).
"""
import sqlite3
import msgpack
import json
import sys
from pathlib import Path

DB_PATH = "/app/data/openfang.db"
MAX_MSGS_PER_AGENT = 80
MAX_TEXT_PREVIEW = 800  # chars per text block — keep enough for context, cap to avoid blowing reviewer's context


def simplify_blocks(blocks):
    """Convert content blocks to a compact JSON-friendly form."""
    if isinstance(blocks, str):
        return [{"type": "text", "text": blocks[:MAX_TEXT_PREVIEW]}]
    out = []
    for b in blocks or []:
        if not isinstance(b, dict):
            out.append({"type": "unknown", "raw": str(b)[:200]})
            continue
        btype = b.get("type", "?")
        if btype == "text":
            out.append({"type": "text", "text": (b.get("text", "") or "")[:MAX_TEXT_PREVIEW]})
        elif btype == "tool_use":
            out.append({
                "type": "tool_use",
                "name": b.get("name", "?"),
                "input_preview": json.dumps(b.get("input", {}), default=str)[:300],
            })
        elif btype == "tool_result":
            content = b.get("content", "")
            if isinstance(content, list):
                content = " | ".join(
                    c.get("text", "") if isinstance(c, dict) else str(c)
                    for c in content
                )
            out.append({"type": "tool_result", "preview": str(content)[:300]})
        else:
            out.append({"type": btype, "raw": json.dumps(b, default=str)[:200]})
    return out


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 7
    if not Path(DB_PATH).exists():
        print(json.dumps({"error": f"DB not found at {DB_PATH}"}))
        sys.exit(1)

    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    out = {
        "dumped_at": __import__("datetime").datetime.utcnow().isoformat() + "Z",
        "max_msgs_per_agent": MAX_MSGS_PER_AGENT,
        "days_requested": days,
        "agents": {},
    }

    rows = conn.execute("""
        SELECT a.name, a.id, s.messages, s.updated_at, s.context_window_tokens
        FROM agents a
        LEFT JOIN sessions s ON s.agent_id = a.id
    """).fetchall()

    for name, aid, blob, updated_at, ctx_tokens in rows:
        agent_entry = {
            "agent_id": aid,
            "session_updated_at": updated_at,
            "context_window_tokens": ctx_tokens,
            "messages": [],
        }
        if blob:
            try:
                msgs = msgpack.unpackb(blob, raw=False)
                tail = msgs[-MAX_MSGS_PER_AGENT:] if len(msgs) > MAX_MSGS_PER_AGENT else msgs
                agent_entry["total_messages_in_session"] = len(msgs)
                agent_entry["showing_tail"] = len(tail)
                agent_entry["messages"] = [
                    {"role": m.get("role", "?"), "content": simplify_blocks(m.get("content", []))}
                    for m in tail
                ]
            except Exception as e:
                agent_entry["error"] = f"msgpack decode failed: {e}"
        out["agents"][name] = agent_entry

    # Also include usage_events of last `days` days (cost signal — see if Leandro is
    # consuming too many tokens per session).
    cutoff_dt = __import__("datetime").datetime.utcnow() - __import__("datetime").timedelta(days=days)
    cutoff_iso = cutoff_dt.isoformat()
    events = conn.execute("""
        SELECT u.timestamp, a.name, u.input_tokens, u.output_tokens, u.tool_calls, u.cost_usd
        FROM usage_events u
        JOIN agents a ON u.agent_id = a.id
        WHERE u.timestamp >= ?
        ORDER BY u.timestamp DESC
        LIMIT 500
    """, (cutoff_iso,)).fetchall()
    out["usage_events_last_period"] = [
        {
            "ts": ts, "agent": name, "in": ti, "out": to, "tools": tc, "cost_usd": cost,
        }
        for ts, name, ti, to, tc, cost in events
    ]

    print(json.dumps(out, default=str, indent=2))


if __name__ == "__main__":
    main()
