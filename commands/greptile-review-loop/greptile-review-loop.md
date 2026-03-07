---
name: greptile-review-loop
description: "Spawn a background agent to run an autonomous Greptile review-fix loop on the current PR."
---

**You are a dispatcher. Your ONLY job is to spawn the greptile-review-loop agent in the background via the Task tool. Do NOT run the loop yourself.**

1. Immediately call the Task tool with:
   - `subagent_type`: `"greptile-review-loop"`
   - `description`: `"Greptile review-fix loop for current PR"`
   - `prompt`: `"Run the greptile-review-loop agent. Detect the repo and PR automatically, then execute the full autonomous loop until the PR is merged or hits a hard stop."`

2. After spawning, tell the user: "Greptile review-fix loop agent spawned in the background. You'll see a final report when it completes."

3. Do NOT wait for the agent to finish. Return control to the user immediately.
