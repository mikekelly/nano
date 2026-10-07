# Seeding: images

## Outcome

An agent whose model can see images can see them. When this is done, a person sends an
agent a message with a picture in it, from the dashboard or the API, and the agent sees the
picture, not a path to it; an agent looks at an image file on the node, such as a
screenshot of a page it rendered with Lightpanda (`lightpanda fetch --dump png`), and sees
that too; and operators see the same images on the agent's timeline. An agent whose model
cannot see images is told so plainly whenever one reaches it, because a model that silently
gets a filename where a picture should be will guess at what it shows. The system prompt says
what the agent can and cannot see, and stays true for every model.

## Considerations

- Which models take images is in the providers' model lists (OpenRouter's
  `architecture.input_modalities`, the Codex backend's `input_modalities`). The seed's
  `Nano.Model` does not keep it yet. Record it when an agent starts, as the context window
  is, so a restart does not depend on the list.
- The wire formats differ, and getting them wrong fails every request:
  - OpenRouter's chat completions take images as `image_url` parts (a `data:` URL) in a user
    message. Tool messages cannot carry images on every provider behind it, so an image an
    eval returns has to reach the model in a user message after the tool results.
  - The Codex backend's Responses API takes `input_image` parts in a user message, and a
    `function_call_output` may itself be a list of content items that includes images (the
    Codex CLI's own image viewer returns them that way).
- Keep the image data out of the stored transcript, the agent's saved state and the logs:
  they are written on every turn, and the transcript is sent to the model on every call.
  Store a reference, and add the data only when a request is built, from a file that never
  changes, so the same image is the same bytes every time and the cached prefix stays
  valid.
- The harness estimates each request's size before sending it, to stop before the context
  limit, and counts what was added since the last response at one token per two bytes. A
  base64 image would count as hundreds of thousands of tokens that way. An image costs a
  few thousand tokens at high detail (Claude up to about 4,800; OpenAI and Gemini less), so
  count it by such a figure, and let the next response's usage correct it.
- Providers limit images: about 5 MB of base64 per image at the strictest, and Claude
  refuses images over 8,000 pixels a side, or over 2,000 once a request carries more than
  20 images. Transcripts only grow, so one oversized image in a long conversation can get
  every later request refused. Check type, size and dimensions before an image enters the
  conversation, not after.
- Check an image's type from its bytes, not its name: models are told the type, and a
  wrong one is refused.
- The dashboard and the API are the operators' view; images that reach an agent should be
  visible there too, so operators can see what it saw.

## Inspiration

- pi's `read` tool, which returns image files as attachments.
- The Codex CLI's `view_image` tool (github.com/openai/codex, `codex-rs/core/src/tools/handlers/view_image.rs`).
- OpenRouter's image-understanding docs; OpenAI's Responses API docs on `input_image`.
- [web-access.md](web-access.md) and [bots.md](bots.md): rendered pages and a chat with
  attachments are where images come from.

How you build it is yours to decide.
