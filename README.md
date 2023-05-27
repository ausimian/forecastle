# Forecastle

Build-time support for hot-code upgrades.

`Forecastle` provides build-time support for the generation of releases that correctly support hot-code 
upgrades. This includes:

  - Copying appup and relup files into place.
  - Organising the generated release structure so that it's ready for hot-code upgrades.
  - Replacing the shell script with one that supports release unpacking and installtion

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
  - The shell-script in the `bin` folder is replaced with one that provides
    additional commands to manage releases.
  - Any `runtime.exs` is copied into the version path of the release.
  - The generated _name.rel_ is copied into the `releases` folder as _name-vsn.rel_.
  - Any `relup` file is copied into the version path of the release.

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
   
## Relup Generation

Forecastle contains a mix task, `forecastle.relup`, that simplifies the generation of
the relup file. Assuming you have two _unpacked_ releases e.g. `0.1.0` and `0.1.1` 
and you wish to generate a relup between them:

```shell
> mix forecastle.relup --target myapp/releases/0.1.1/myapp --fromto myapp/releases/0.1.0/myapp
```

If the generated file is in the project root, it will be copied during 
post-assembly to the release.