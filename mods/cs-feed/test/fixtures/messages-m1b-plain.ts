// ABOUTME: Recorded engine messages packaged for the kit code-only loader.
// ABOUTME: The exported data is copied from the adjacent JSON fixture.
export default [
 {
  "role": "assistant",
  "text": "ok",
  "toolUses": []
 },
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
    "tool_use_id": "toolu_fa3d1ee0d8c942b99da7",
    "tool": "Bash",
    "input": {
     "command": "sleep 30; echo slept",
     "description": "Sleep thirty seconds"
    },
    "result": {
     "stdout": "slept",
     "stderr": "",
     "interrupted": false,
     "isImage": false,
     "noOutputExpected": false
    },
    "text": "slept"
   }
  ]
 },
 {
  "role": "user",
  "text": "",
  "toolUses": [],
  "toolResults": [
   {
    "tool_use_id": "toolu_fa3d1ee0d8c942b99da7",
    "text": "slept",
    "isError": false,
    "result": {
     "stdout": "slept",
     "stderr": "",
     "interrupted": false,
     "isImage": false,
     "noOutputExpected": false
    }
   }
  ]
 },
 {
  "role": "assistant",
  "text": "TOOLDONE after the tool.",
  "toolUses": []
 }
]
