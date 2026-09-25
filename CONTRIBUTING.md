# Developing RailsMind

This repository owns the MIT-licensed client SDK, browser adapter, tests, and SDK
documentation. The hosted RailsMind application and its internal integration
sample are maintained separately and remain proprietary.

## Setup

Use Ruby 4.0.6 and Node 22 for the currently verified combination.

```sh
git clone https://github.com/cmartyn/rails_mind.git
cd rails_mind
bundle install
bundle exec rake test
node --test javascript/rails_mind.test.js
bundle exec ruby script/package_smoke.rb
```

No database or hosted service is required for this repository's tests. See
[compatibility](docs/compatibility.md) for coverage and limits.

## Testing a development revision

Applications normally install a released version from RubyGems.org. To evaluate
an unreleased change, use a reviewed full commit SHA:

```ruby
gem "rails_mind", git: "https://github.com/cmartyn/rails_mind.git", ref: "<full commit SHA>"
```

Commit the application's lockfile and run its integration tests when upgrading.
A local `path:` dependency can be used temporarily while developing both
projects; do not commit that override. GitHub credentials are not required to
read this public repository.

## Packaging and releases

`bundle exec ruby script/package_smoke.rb` builds a temporary gem and exercises its
packaged installer and browser files. `bundle exec rake build` writes the gem to
`pkg/`. Neither command publishes anything.

Publishing uses [RubyGems trusted publishing](https://guides.rubygems.org/trusted-publishing/)
from `.github/workflows/release.yml`, with no stored RubyGems API key. The gem's
owner configures these values on RubyGems.org:

| Field | Value |
| --- | --- |
| Gem name | `rails_mind` |
| Repository owner | `cmartyn` |
| Repository name | `rails_mind` |
| Workflow filename | `release.yml` |
| GitHub environment | `release` |

For the first release, create a pending trusted publisher under the intended
owner's RubyGems.org profile. A successful first push registers the gem and assigns
that account ownership. The repository's `release` environment must allow release
tags; configure required reviewers when additional approval is desired.

Before releasing, update `lib/rails_mind/version.rb` and `CHANGELOG.md`, run the
checks above, complete staging validation appropriate to the documented
compatibility promise, and merge the release commit into `main`. Keep known
limitations explicit; a passing unit test suite does not certify a deployed
customer application.

Create an annotated tag matching the gem version and push it:

```sh
git tag -a v0.1.0 -m "Release rails_mind 0.1.0"
git push origin v0.1.0
```

The workflow verifies the tag/version, reruns the Ruby, JavaScript, and package
checks, then publishes to RubyGems.org. Confirm the published version can be
installed before announcing the release. Published version numbers cannot be
reused; fixes need a new version.

## Origin

The SDK was extracted into its own repository on 2026-09-15. Its earlier history
remains in the private application repository; only the client is licensed here.
