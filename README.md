# Demofy Demo Video action

Record a product demo video of any URL from a one-line goal, straight from a GitHub workflow.
[Demofy](https://demofy.io) plans the clicks, records the page, adds a voice-over and captions, and
hands back an MP4. This action creates the job, waits for it, and attaches the video to the run as an
artifact, with a link in the step summary.

Use it on a pull request's preview deploy to show reviewers what changed, or on a release to get a
fresh product demo every time you ship.

## Quick start

1. In Demofy, open **Settings > API keys** and create a key with the **write** permission.
2. In your repository, add it as an Actions secret named `DEMOFY_API_KEY`
   (**Settings > Secrets and variables > Actions**).
3. Add a step:

```yaml
- uses: DevinoSolutions/demofy-action@v1
  with:
    api-key: ${{ secrets.DEMOFY_API_KEY }}
    url: https://your-app.example.com
    prompt: Show how a new project is created and shared
```

The run gets an MP4 artifact named `demofy-<job-id>.mp4`, and the step summary links the job page and
the video.

## Inputs

| Input | Required | Default | What it is |
| --- | --- | --- | --- |
| `api-key` | yes | | A Demofy API key (`dmf_...`) with the write permission. Pass it from a secret. |
| `url` | yes | | The page to record. |
| `prompt` | yes | | What the demo should show. Up to 500 characters on Free, 4000 on Pro. |
| `quality` | no | free tier | `standard`, `high` or `ultra`. `high` and `ultra` need Pro. |
| `format` | no | `desktop` | `desktop` or `mobile`. |
| `capture-profile` | no | | `compact`: a smaller desktop viewport at the same output resolution. |
| `connection-id` | no | | A saved Demofy connection, to record signed in. |
| `pacing` | no | `brisk` | `brisk` or `unhurried` voice-over. |
| `captions` | no | workspace setting | `off`, `plate`, `minimal`, `pop` or `headline`. |
| `narration` | no | spoken | `off` for no voice-over. |
| `music` | no | default track | A built-in track id, or `off`. |
| `voice-profile-id` | no | workspace voice | A voice id from `GET /api/voices` (Pro). |
| `setup-url` | no | | A same-origin page that resets the demo account before recording. |
| `look` | no | | JSON object of look names, e.g. `{"backdrop":"beam","padding":"snug"}`. |
| `extra-json` | no | | JSON object merged into the create request last, for any other [API field](https://demofy.io/docs/api). |
| `wait` | no | `true` | `false` ends the step as soon as the job is created. |
| `timeout-minutes` | no | `60` | How long to wait, 1 to 180. Most demos take 5 to 30 minutes. |
| `upload-artifact` | no | `true` | Upload the MP4 to the run. |
| `artifact-name` | no | `demofy-<job-id>` | File and artifact name for the MP4, without `.mp4`. |
| `retention-days` | no | repository default | Days to keep the artifact, 1 to 90. |
| `base-url` | no | `https://app.demofy.io` | The Demofy app origin. |

## Outputs

| Output | What it is |
| --- | --- |
| `job-id` | The Demofy job id. |
| `status` | The last status: `queued`, `discovering`, `capturing`, `compositing`, `uploading`, `done` or `failed`. |
| `page-url` | The job page in Demofy (opens for members of the workspace). |
| `video-url` | A signed link to the MP4, valid for 7 days. |
| `share-url` | The public share link, when sharing is on for the job. |
| `video-path` | Where the MP4 was saved on the runner. |
| `artifact-url` | The MP4 artifact on the workflow run. |
| `error-code` | Demofy's stable error code when the job failed, e.g. `page_not_found`. |

## Example: a demo of every pull request preview

Record the preview once its deploy is up, and comment the links on the pull request.

```yaml
name: PR demo
on:
  pull_request:
    types: [opened, labeled]

jobs:
  demo:
    # Each run spends one of the account's daily demos, so ask for it with a label.
    if: contains(github.event.pull_request.labels.*.name, 'demo')
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - id: preview
        run: echo "url=https://pr-${{ github.event.pull_request.number }}.preview.example.com" >> "$GITHUB_OUTPUT"

      - id: demofy
        uses: DevinoSolutions/demofy-action@v1
        with:
          api-key: ${{ secrets.DEMOFY_API_KEY }}
          url: ${{ steps.preview.outputs.url }}
          prompt: Show the settings page and the new export button

      - env:
          GH_TOKEN: ${{ github.token }}
          PR: ${{ github.event.pull_request.number }}
          PAGE_URL: ${{ steps.demofy.outputs.page-url }}
          ARTIFACT_URL: ${{ steps.demofy.outputs.artifact-url }}
        run: gh pr comment "$PR" --repo "$GITHUB_REPOSITORY" --body "Demo video: [MP4]($ARTIFACT_URL) | [Demofy job]($PAGE_URL)"
```

## Example: a product demo on every release

Attach the video to the release itself.

```yaml
name: Release demo
on:
  release:
    types: [published]

jobs:
  demo:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - id: demofy
        uses: DevinoSolutions/demofy-action@v1
        with:
          api-key: ${{ secrets.DEMOFY_API_KEY }}
          url: https://your-app.example.com
          prompt: Show what is new in this release, starting from the dashboard
          quality: high
          artifact-name: demo-${{ github.event.release.tag_name }}

      - env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ github.event.release.tag_name }}
          VIDEO_PATH: ${{ steps.demofy.outputs.video-path }}
        run: gh release upload "$TAG" "$VIDEO_PATH" --repo "$GITHUB_REPOSITORY"
```

## When the step fails

The step fails, with Demofy's own sentence, when:

- the key is wrong or revoked (`401`), or lacks the write permission (`403`);
- a field needs a paid plan (`402`), for example `quality: high` on a Free workspace;
- an allowance is spent or the key is rate limited (`429`, with how long to wait);
- the request is invalid (`400`, listing each field) or refused by a rule (`422`);
- the job fails: `error-code` holds Demofy's code and the log has the reason;
- the page needs a sign-in: the log links the job's sign-in page. Record behind a login with a saved
  connection (`connection-id`) instead;
- `timeout-minutes` passes. The job keeps running in Demofy; the job page has it;
- GitHub refuses the artifact, for example when the account's artifact storage quota is used up. The
  video is still on the runner: set `upload-artifact: false` and use `video-path` or `video-url`.

Short network errors and `5xx` answers while waiting are retried; a `429` while waiting is honoured
with its `Retry-After`.

## Limits

Allowances belong to the Demofy account, not to the key or the repository, so more keys or more
workflows never mean more demos:

- 10 demos per person per rolling 24 hours, and 4 running at once. Pro does not raise these; a job
  that fails does not count. See [Limits](https://demofy.io/docs/limits).
- Each API key is limited to 120 requests a minute. The action polls every 10 to 30 seconds.
- Pro levers (`quality: high`/`ultra`, `voice-profile-id`, prompts over 500 characters) are refused
  with `402` on a Free workspace.

Scope the step with `if:` (a label, a branch, a release) so it does not spend the day's demos on
every push.

## Security

- The key is masked in the log and never passed on the command line: curl reads the
  `Authorization` header from a private temporary file that is deleted when the step ends.
- Only keys that start with `dmf_` are sent; anything else stops the step before any request.
- The signed `video-url` is valid for 7 days and the step summary shows it, so anyone who can read
  the run can download the video for that long. The artifact follows your repository's retention.

## Runners

GitHub-hosted Linux, Windows and macOS runners have everything the action needs (`bash`, `curl`,
`jq`). On a self-hosted runner, install `curl` and `jq`. CI runs the test suite on Ubuntu and
Windows.

## Development

```bash
bash tests/run.sh   # the action's script against a local mock of the Demofy API (python3, curl, jq)
```

`shellcheck` and `actionlint` run in CI, with the mock suite, an end-to-end run of the action
(`uses: ./`) against the mock, and its refusal path.
