# Developing RailsMind

This repository owns the customer SDK, browser adapter, tests, and SDK documentation.
The hosted Rails application and integration sample live in
[cmartyn/mind](https://github.com/cmartyn/mind).

## Setup

Use Ruby 4.0.6 and Node 22 for the currently verified combination.

```sh
gh repo clone cmartyn/rails_mind
cd rails_mind
bundle install
bundle exec rake test
node --test javascript/rails_mind.test.js
bundle exec ruby script/package_smoke.rb
```

No database or hosted service is required for this repository's tests. See
[compatibility](docs/compatibility.md) for coverage and limits.

## Private repository access

For local HTTPS installs, authenticate Git with an account that has repository
access (for example, `gh auth login` followed by `gh auth setup-git`). Never put
credentials into a Gemfile or lockfile. Automation should use a read-only deploy
key scoped to this repository and keep the private key in its secret store.

For unpublished installs, the README uses `branch: "main"`; Bundler records the
selected commit in the consuming application's lockfile. For a deliberate upgrade,
review the desired SDK commit and set `ref: "<full commit SHA>"` in that application's
Gemfile, then update its lockfile and run its integration tests.

The hosted app and sample pin a reviewed commit. To update them, change both
Gemfiles, both lockfiles, and the installation example in the Setup page and docs.
A local `path:` dependency can be used temporarily while developing both projects;
do not commit that override.

## Packaging and releases

`bundle exec ruby script/package_smoke.rb` builds a temporary gem and exercises its
packaged installer and browser files. It does not publish anything. Version 0.1.0
is an unpublished pilot; this repository has no automatic publishing workflow.
Before a release, agree on the compatibility promise, complete staging validation,
write release notes, choose a version/tag, and configure RubyGems ownership and
trusted publishing separately.

## Origin

Extracted from `cmartyn/mind` commit
`7c33e4f6cffa6af4835671b8eabf33e3bab44834` on 2026-09-15. The source's earlier
history remains in that repository. SDK changes now belong here.
