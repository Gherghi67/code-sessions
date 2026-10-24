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
    "tool_use_id": "toolu_94ff9e02b6c444a3a537",
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
    "tool_use_id": "toolu_94ff9e02b6c444a3a537",
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
