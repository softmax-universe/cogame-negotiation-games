## Negotiation Games player: canonical model player and explicit baselines.
##
## Modes:
## 1. Explicit scripted baseline (`PLAYER_SCRIPTED=haggler|hardliner`):
##    registers the chosen deterministic baseline with the server (no LLM).
## 2. Player-side model policy (`COWORLD_LLM_ENABLED=true` or model endpoint/
##    credentials routed to this container): registers `control: "external"`
##    with its operator prompt, receives per-turn observations from the game
##    server, makes a single model call to `COWORLD_LLM_ENDPOINT` with
##    `COWORLD_LLM_MODEL`, and returns the canonical action with raw attempt
##    evidence (or reports explicit failure without fallback or retries).
## 3. Server-side prompt policy (no `PLAYER_SCRIPTED`, no player-side LLM env):
##    delivers `PLAYER_PROMPT` so the game server invokes its own LLM client.

import
  std/[json, options, os, strutils],
  bitworld/decision_trajectory,
  negotiation/[llm, sim],
  whisky

const DefaultPrompt = """
Open by taking the whole pool and say which item you need most. Concede in
small steps, always giving away the item that is worth least to you per
unit and never the one you value most. Watch what your opponent keeps
asking for - that is what they value - and charge them for it while you
take the rest. Accept the standing offer when it is worth 6 or more to
you, or when three or fewer turns remain and it is worth 4 or more. On the
last turn available to you, accept anything worth 1 or more: a deal you
dislike still beats the zero that both of you get when the turns run out.
"""

proc playerOwnsModelCalls(scripted: string): bool =
  if scripted.len > 0:
    return false
  if getEnv("COWORLD_LLM_ENABLED").strip().toLowerAscii() == "true":
    return true
  for key in [
    "COWORLD_LLM_ENDPOINT",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_API_KEY_URI",
    "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
    "AWS_BEARER_TOKEN_BEDROCK",
  ]:
    if getEnv(key).strip().len > 0:
      return true
  false

proc handleObservation(socket: WebSocket, client: LlmClient, payload: JsonNode) =
  let eventId = payload{"event"}.getInt(-1)
  if eventId < 0:
    return
  if client.isNil or client.disabled:
    socket.send($ %*{
      "type": "action_failed",
      "event": eventId,
      "reason": "LLM transport unavailable or unauthenticated for model seat",
      "status": "missing"
    })
    return
  let inputNode = payload{"input"}
  let system = if not inputNode.isNil: inputNode{"system"}.getStr() else: ""
  let user = if not inputNode.isNil: inputNode{"user"}.getStr() else: ""
  var evidence = newDecisionAttempt("attempt-0", client.model, aoModel)
  var raw = ""
  try:
    raw = client.completeText(system, user, -1, evidence)
    let actionPayload = parseJsonObject(raw)
    evidence.response = %raw
    socket.send($ %*{
      "type": "action",
      "event": eventId,
      "action": actionPayload,
      "attempts": [attemptEvidenceJson(evidence)]
    })
  except CatchableError as error:
    evidence.response = %raw
    evidence.rejectionReason = some(error.msg)
    echo "negotiation player: model decision failed: ", error.msg
    socket.send($ %*{
      "type": "action_failed",
      "event": eventId,
      "reason": error.msg,
      "status": "rejected",
      "attempts": [attemptEvidenceJson(evidence)]
    })

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  let externalModel = playerOwnsModelCalls(scripted)
  let client = if externalModel: newLlmClient(defaultGameConfig()) else: nil

  proc registrationFrame(): string =
    if externalModel:
      $ %*{"type": "register", "control": "external", "prompt": prompt}
    else:
      $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "negotiation player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(registrationFrame())
  if externalModel:
    echo "negotiation player: registered external model seat (model ",
      (if not client.isNil: client.model else: ""), ", disabled=",
      (if not client.isNil: $client.disabled else: "true"), ")"
  else:
    echo "negotiation player: prompt delivered (", prompt.len, " chars",
      (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and the game's quit(0) can outrun the
  ## flushed final frame. An unhandled raise here exits 1 and fails
  ## certification with player_error on a coin flip (cogame-raid 0.1.4).
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "negotiation player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "negotiation player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
          ## Re-deliver registration after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(registrationFrame())
        of "observation":
          if externalModel:
            handleObservation(socket, client, payload)
        of "final":
          echo "negotiation player: final scores ", payload{"scores"}
          break
        of "failed":
          echo "negotiation player: episode failed (seat ",
            payload{"failedSeat"}.getInt(-1), "): ", payload{"reason"}.getStr()
          break
        else:
          discard
      except CatchableError as error:
        echo "negotiation player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "negotiation player: socket closed (", error.msg, "), exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
