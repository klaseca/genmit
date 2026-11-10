name = "klaseca/genmit"

version = "0.3.0"

repository = "https://github.com/klaseca/genmit"

description = "Generate AI-assisted commit messages from staged Git changes"

keywords = [ "git", "commit-message", "llm", "ai", "cli" ]

license = "Apache-2.0"

readme = "README.md"

preferred_target = "native"

supported_targets = "+js+native+wasm"

source = "src"

import {
  "moonbit-community/toml@0.5.1",
  "moonbitlang/async@0.22.7",
  "moonbitlang/x@0.5.7",
}
