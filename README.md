# Forecastle

Build-time support for hot-code upgrades.

`Forecastle` provides build-time support for the generation of releases that correctly support hot-code 
upgrades. This includes:

  - Copying appup and relup files into place.
  - Organising the generated release structure so that it's ready for hot-code upgrades.
  - Adding a `bin/castle` command for unpacking and installing releases, alongside
    the standard Mix launcher.

Additionally, `Forecastle` ships with a appup compiler and a mix task for relup generation.

## Installation

`Forecastle` is not intended to be taken as a direct dependency.  Most applications should prefer to
take a dependency on [Castle](https://hexdocs.pm/castle/readme.html) directly which will, in turn 
take a build-time dependency on `Forecastle`.

For projects that don't define a release, but use the `appup` compiler, it's sufficient to 
bring `Castle` in as a build-time dependency:

```elixir
def deps do
  [
    {:castle, "~> 0.3.0", runtime: false}
  ]
end
```

For projects that _do_ define one or more releases, `Castle` should be brought in
as a runtime dependency:

```elixir
def deps do
  [
    {:castle, "~> 0.3.0"}
  ]
end
```

## Integration

`Forecastle` integrates into the steps of the release assembly process. It requires
that the `Forecastle.pre_assemble/1` and `Forecastle.post_assemble/1` functions are
placed around the `:assemble` step, e.g.:

```elixir
defp releases do
  [
    myapp: [
      include_executables_for: [:unix],
      steps: [&Forecastle.pre_assemble/1, :assemble, &Forecastle.post_assemble/1, :tar]
    ]
  ]
end
```

## Build Time Support

The following steps shape the release at build-time:

### Pre-assembly

In the pre-assembly step:

  - The default evaluation of runtime configuration is disabled. `Forecastle` will
    do its own equivalent expansion into `sys.config` prior to system start,
    first with `runtime.exs` (if it exists) and then with any Config Providers.
  - A 'preboot' boot script is created that starts only `Forecastle` and its
    dependencies. This is used only during the aforementioned expansion.

The system is then assembled under the `:assemble` step as normal.

### Post-assembly

In the post-assembly step:

  - The `sys.config` generated from build-time configuration is copied to 
    `build.config`.
  - A `bin/castle` command is added, providing the commands that manage releases.
    The standard `bin/<release>` launcher that Mix generates is left untouched.
  - The generated `env.sh` is extended, so that the configuration in
    `build.config` is expanded into `sys.config` before the system boots. Any
    `env.sh` the project supplies through `rel/env.sh.eex` is preserved, and
    runs first.
  - Any `runtime.exs` is copied into the version path of the release.
  - The generated _name.rel_ is copied into the `releases` folder as _name-vsn.rel_.
  - Any `relup` file is copied into the version path of the release.

## Managing Releases

The release itself is controlled through the standard launcher that Mix generates,
which `Forecastle` does not modify:

```shell
> myapp/bin/myapp start
> myapp/bin/myapp remote
> myapp/bin/myapp rpc "..."
> myapp/bin/myapp stop
```

Moving the running system from one version to the next is done through `bin/castle`:

```shell
# List the releases the system knows about, and their status.
> myapp/bin/castle releases

# Unpack myapp-0.1.1.tar.gz, which you have placed in myapp/releases.
> myapp/bin/castle unpack 0.1.1

# Make 0.1.1 the version that is running now, without restarting the VM.
> myapp/bin/castle install 0.1.1

# Make it the version that runs on restart too. With no version given, this
# commits whichever version is running.
> myapp/bin/castle commit

# Or, having decided against it, remove it again.
> myapp/bin/castle remove 0.1.1
```

Version selection on restart needs nothing from `Forecastle`: OTP's
`release_handler` records the committed version in `releases/start_erl.data`,
which is exactly where the standard launcher reads it from.

## The Appup Compiler

You are responsible for writing the [appup](https://www.erlang.org/doc/man/appup.html)
scripts for your application, but `Forecastle` will copy the appup into the `ebin` folder
for you. The steps are as follows:

1. Write a file, in _Elixir form_, describing the application upgrade. e.g.:
   ```elixir
   # You can call the file what you like, e.g. appup.exs,
   {
    '0.1.1', # Code is eval'd so can also: to_charlist(Mix.Project.config[:version]),
     [
      {'0.1.0', [
        {:update, MyApp.Server, {:advanced, []}}
      ]}
     ],
     [
      {'0.1.0', [
        {:update, MyApp.Server, {:advanced, []}}
      ]}
     ]
   }
   ```
   This file will typically be checked in to SCM.
2. Add the appup file to the Mix project definition in mix.exs and add the
   `:appup` compiler.
   ```elixir
   # Mix.exs
   def project do
     [
       appup: "appup.exs", # Relative to the project root.
       compilers: Mix.compilers() ++ [:appup]
     ]
   end
   ```

The compiler owns `<app>.appup` for the whole of its life. It rewrites it on every
build, and deletes it again if the source goes away or the `:appup` key is dropped,
so that an incremental build cannot ship upgrade instructions belonging to an
earlier version. Naming a file that does not exist is a compilation error: the
project asked for an appup and cannot have one.

That housekeeping only happens while the compiler is registered. To turn an appup
off for some environments, leave `:appup` in `:compilers` and let the `:appup` key
be `nil` - the output is removed and nothing further is reported. Taking the
compiler out of `:compilers` instead stops it running, and an output an earlier
build wrote stays where it is.

## Relup Generation

Forecastle contains a mix task, `forecastle.relup`, that simplifies the generation of
the relup file. Assuming you have two _unpacked_ releases e.g. `0.1.0` and `0.1.1` 
and you wish to generate a relup between them:

```shell
> mix forecastle.relup --target myapp/releases/0.1.1/myapp --fromto myapp/releases/0.1.0/myapp
```

If the generated file is in the project root, it will be copied during
post-assembly to the release. That is where the task writes it by default;
`--outdir` sends it somewhere else, which post-assembly will not find, and a
relative `--outdir` is resolved from the directory the task is run in rather
than from the project root. The directory has to exist already: a mistyped one
that sprang into existence is how a relup ends up somewhere nothing looks for.

The task fails if it could not generate the relup, so a build pipeline can tell,
and it leaves any earlier relup alone rather than half-replacing it. Assembly
then checks the relup it is about to package really is this release's upgrade
plan - the right target version, with the upgrade and downgrade sections
`release_handler` will read - and fails if it is not. Between them, a build
cannot quietly ship the previous version's plan.
