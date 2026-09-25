///|
async fn run_git(
  cwd : String,
  args : Array[String],
  runner : async (ProcessRequest) -> ProcessOutput,
  trim? : Bool = true,
) -> String {
  let output = execute_process(
    {
      command: "git",
      args,
      cwd,
      input: "",
      timeout_ms: 180000,
      maximum_output_bytes: 16 * 1024 * 1024,
    },
    runner,
  )

  if output.code == 0 {
    if trim {
      output.stdout.trim().to_owned()
    } else {
      output.stdout
    }
  } else {
    let details = output.stderr.trim().to_owned()
    raise @genmit.GenmitError(
      if details == "" {
        "git \{args.join(" ")} exited with code \{output.code}"
      } else {
        "git \{args.join(" ")} failed: \{details}"
      },
    )
  }
}

///|
/// Resolve the repository containing `cwd` through the supplied process host.
pub async fn repository_root(
  cwd : String,
  runner : async (ProcessRequest) -> ProcessOutput,
) -> String {
  run_git(cwd, ["rev-parse", "--show-toplevel"], runner)
}

///|
/// Collect staged Git state through the supplied process host.
async fn collect_git_context(
  cwd : String,
  runner : async (ProcessRequest) -> ProcessOutput,
) -> @genmit.GitContext {
  let root = repository_root(cwd, runner)

  let files_text = run_git(
    root,
    ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACDMRTUXB", "--"],
    runner,
    trim=false,
  )

  let files = files_text
    .split("\u{0000}")
    .map(line => line.to_owned())
    .filter(line => line != "")
    .to_array()

  if files.length() == 0 {
    raise @genmit.GenmitError("no staged changes found")
  }

  let branch = run_git(root, ["branch", "--show-current"], runner)

  let branch = if branch == "" { "HEAD (detached)" } else { branch }

  let raw_diff = run_git(
    root,
    [
      "diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames",
      "--unified=3", "--",
    ],
    runner,
    trim=false,
  )

  let recent_commits = run_git(
    root,
    ["log", "--ignore-missing", "-5", "--pretty=format:%s", "HEAD"],
    runner,
  )

  let recent_commits = if recent_commits == "" {
    "No previous commits"
  } else {
    recent_commits
  }

  { root, branch, staged_files: files, diff: raw_diff, recent_commits, }
}
