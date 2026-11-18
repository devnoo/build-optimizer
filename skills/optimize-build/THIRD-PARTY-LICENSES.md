# Third-party notices

The optimize-build skill is MIT licensed (see the repository `LICENSE`). Two parts are adapted from other
projects and stay under those projects' licenses.

## github/awesome-copilot — MIT

- **Repo:** https://github.com/github/awesome-copilot
- **Source:** `skills/github-actions-efficiency`
- **Copyright:** `Copyright GitHub, Inc.`
- **Used for:** the guardrails, the waste audit and the three-number report in `SKILL.md` and `WORKFLOW.md`.
- **Modified:** yes — rewritten and merged into this skill's measure-first procedure.

> MIT License
>
> Copyright GitHub, Inc.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## docker/skills — Apache-2.0

- **Repo:** https://github.com/docker/skills
- **Source:** `skills/docker-build-strategies`
- **Used for:** Docker checks in `references/stack/docker.md` and the Docker lane prompt in `WORKFLOW.md`
  (layer order, bind-mounted manifests, cache-mount targets, `--progress=plain`).
- **Modified:** yes — rewritten, re-verified against the Docker docs and extended with CI cache checks.
- **License text:** https://www.apache.org/licenses/LICENSE-2.0
