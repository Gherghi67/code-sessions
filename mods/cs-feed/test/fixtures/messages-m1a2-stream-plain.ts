// ABOUTME: Recorded engine messages packaged for the kit code-only loader.
// ABOUTME: The exported data is copied from the adjacent JSON fixture.
export default [
 {
  "role": "user",
  "text": "SLOWTOOL run it",
  "toolUses": []
 },
 {
  "role": "assistant",
  "text": "",
  "toolUses": [
   {
    "tool_use_id": "toolu_f98f3fa9a8a2482d8bc4",
    "tool": "Bash",
    "input": {
     "command": "sleep 30; echo slept",
     "description": "Sleep thirty seconds"
    },
    "result": {
     "stdout": "",
     "stderr": "",
     "interrupted": false,
     "isImage": false,
     "noOutputExpected": false,
     "backgroundTaskId": "b1yl3laxk",
     "backgroundedToDeliverMessage": true
    },
    "text": "Command was moved to the background (ID: b1yl3laxk) so that a message that arrived while it was running can reach you; it was not interrupted. Output is being written to: /private/tmp/claude-501/-private-tmp-claude-501--Users-test-user--claude-sessions-claude-sessions-b0aeede7-ae27-42ab-b832-30ff969ac62d-scratchpad-feed-spike-work/5b51091b-4826-41d4-a52a-fbc890b2b4ce/tasks/b1yl3laxk.output. You will be notified when it completes. To check interim output, use Read on that file path."
   }
  ]
 },
 {
  "role": "user",
  "text": "",
  "toolUses": [],
  "toolResults": [
   {
    "tool_use_id": "toolu_f98f3fa9a8a2482d8bc4",
    "text": "Command was moved to the background (ID: b1yl3laxk) so that a message that arrived while it was running can reach you; it was not interrupted. Output is being written to: /private/tmp/claude-501/-private-tmp-claude-501--Users-test-user--claude-sessions-claude-sessions-b0aeede7-ae27-42ab-b832-30ff969ac62d-scratchpad-feed-spike-work/5b51091b-4826-41d4-a52a-fbc890b2b4ce/tasks/b1yl3laxk.output. You will be notified when it completes. To check interim output, use Read on that file path.",
    "isError": false,
    "result": {
     "stdout": "",
     "stderr": "",
     "interrupted": false,
     "isImage": false,
     "noOutputExpected": false,
     "backgroundTaskId": "b1yl3laxk",
     "backgroundedToDeliverMessage": true
    }
   }
  ]
 },
 {
  "role": "assistant",
  "text": "TOOLDONE after the tool.",
  "toolUses": []
 },
 {
  "role": "user",
  "text": "<task-notification>\n<task-id>b1yl3laxk</task-id>\n<tool-use-id>toolu_f98f3fa9a8a2482d8bc4</tool-use-id>\n<output-file>/private/tmp/claude-501/-private-tmp-claude-501--Users-test-user--claude-sessions-claude-sessions-b0aeede7-ae27-42ab-b832-30ff969ac62d-scratchpad-feed-spike-work/5b51091b-4826-41d4-a52a-fbc890b2b4ce/tasks/b1yl3laxk.output</output-file>\n<status>completed</status>\n<summary>Background command \"Sleep thirty seconds\" completed (exit code 0)</summary>\n</task-notification>",
  "toolUses": []
 },
 {
  "role": "assistant",
  "text": "ok",
  "toolUses": []
 },
 {
  "role": "user",
  "text": "SLOWTEXT go",
  "toolUses": []
 },
 {
  "role": "assistant",
  "text": "word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11 word12 word13 word14 word15 word16 word17 word18 word19 word20 word21 word22 word23 word24 word25 word26 word27 word28 word29 word30 word31 word32 word33 word34 word35 word36 word37 word38 word39",
  "toolUses": []
 },
 {
  "role": "user",
  "text": "MIDSTREAM plain",
  "toolUses": []
 },
 {
  "role": "assistant",
  "text": "ok",
  "toolUses": []
 }
]
