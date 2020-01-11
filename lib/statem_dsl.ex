defmodule PropCheck.StateM.DSL do

  @moduledoc """
  This module provides a shallow DSL (domain specific language) in Elixir
  for property based testing of stateful systems.

  ## The basic approach
  Property based testing of stateful systems is different from ordinary property
  based testing. Instead of testing operations and their effects on the
  data structure directly, we construct a model of the system and generate a sequence
  of commands operating on both, the model and the system. Then we check that
  after each command step, the system has evolved accordingly to the model.
  This is the same idea which is used in model checking and is sometimes called
  a bisimulation.

  After defining a model, we have two phases during executing the property.
  In phase 1, the generators create a list of
  (symbolic) commands including their parameters to be run against the system under test
  (SUT). A state machine guides the generation of commands.

  In phase 2, the commands are executed and the state machine checks that  the
  SUT is in the same state as the state machine. If an invalid state is
  detected, then the command sequence is shrunk towards a shorter sequence
  serving then as counterexamples.

  This approach works exactly the same as with `PropCheck.StateM` and
  `PropCheck.FSM`. The main difference is the API, grouping pre- and postconditions,
  state transitions, and argument generators around the commands of the SUT. This
  leads towards more logical locality compared to the former implementations.
  QuickCheck EQC has a similar approach for structuring their modern state machines.

  ## The DSL

  A state machine acting as a model of the SUT can be defined by focusing on
  states or on transitions. We  focus here on the transitions. A transition is a
  command calling the SUT. Therefore the main phrase of the DSL is the `defcommand`
  macro.

      defcommand :find do
        # define the rules for executing the find command here
      end

  Inside the `command` macro, we define all the rules which the command must
  obey. As an example, we discuss here as an example the slightly simplified
  command `:find` from `test/cache_dsl_test.exs`. The SUT is a cache
  implementation based on an ETS and the model is is based on a list of
  (key/value)-pairs. This example is derived from [Fred Hebert's PropEr Testing,
  Chapter 9](http://propertesting.com/book_stateful_properties.html)

  The `find`-command is a call to the `find/1` API function. Its arguments are
  generated by `key()`, which boils down to numeric values. The arguments for
  the command are defined by the function `args(state)` returning a list
  of generators. In our example, the arguments do not depend on the model state.
  Next, we need to define the execution of the command by defining function
  `impl/n`. This function takes as many arguments as  `args/1` has elements in
  the argument list. The `impl`-function allows to apply conversion of
  parameters and return values to ease the testing. A typical example is the
  conversion of an `{:ok, value}` tuple to only `value` which can simplify
  working with `value`.

      defcommand :find do
        def impl(key), do: Cache.find(key)
        def args(_state), do: [key()]
      end

  After defining how a command is executed, we need to define in which state
  this is allowed. For this, we define function `pre/2`, taking the model state
  and the generated list of arguments to check whether this call is
  allowed in the current model state. In this particular example, `find` is always
  allowed, hence we return `true` without any further checking. This is also the
  default implementation and the reason why the precondition is missing
  in the test file.

      defcommand :find do
        def impl(key), do: Cache.find(key)
        def args(_state), do: [key()]
        def pre(_state, [_key]), do: true
      end

  If the precondition is satisfied, the call can happen. After the call, the SUT
  can be in a different state and the model state must be updated according to
  the mapping of the SUT to the model. The function `next/3` takes the state before
  the call, the list of arguments and the symbolic or dynamic result (depending
  on phase 1 or 2, respectively). `next/3` returns the  new model state.  Since
  searching for a key in the cache does not modify the system nor the model
  state, nothing has to be done. This is again the default implementation and thus
  left out in the test file.

      defcommand :find do
        def impl(key), do: Cache.find(key)
        def args(_state), do: [key()]
        def pre(_state, [_key]), do: true
        def next(old_state, _args, call_result), do: old_state
      end

  The missing part of the command definition is the post condition, checking
  that after calling the system in phase 2 the system is in the expected state
  compared the model. This check is implemented in function `post/3`, which
  again has a trivial default implementation for post conditions that always returns
  true. In this example, we check if the `call_result` is `{:error, :not_found}`,
  then we also do not find the key in our model list `entries`. The other case is
  that if we a return value of `{:ok, val}`, then we also find the value via
  the `key` in our list of `entries`.

      defcommand :find do
        def impl(key), do: Cache.find(key)
        def args(_state), do: [key()]
        def pre(_state, [_key]), do: true
        def next(old_state, _args, _call_result), do: old_state
        def post(entries, [key], call_result) do
          case List.keyfind(entries, key, 0, false) do
              false       -> call_result == {:error, :not_found}
              {^key, val} -> call_result == {:ok, val}
          end
        end
      end

  This completes the DSL for command definitions.

  ## Additional model elements

  In addition to commands, we need to define the model itself. This is the
  ingenious part of stateful property based testing! The initial state
  of the model must be implemented as the function `initial_state/0`. From this
  function, all model evolutions start. In our simplified cache example the
  initial model is an empty list:

      def initial_state(), do: []

  The commands are generated with the same frequency by default. Often, this
  is not appropriate, e.g. in the cache example we expect many more `find` than
  `cache` commands. Therefore, commands can have a weight, which is technically used
  inside a `PropCheck.BasicTypes.frequency/1` generator. The weights are defined
  in callback function `c:weight/1`, taking the current model state and returning
  a map of command and frequency pairs to be generated.  In our cache example
  we want the `find` command to appear three times more often than other commands:

      def weight(_state), do: %{find: 3, cache: 1, flush: 1}

  ## The property to test
  The property to test the stateful system is more or less the same for all systems.
  We generate all commands via generator `commands/1`, which takes
  a module with callbacks as parameter. Inside the test, we first start
  the SUT, execute the commands with `run_commands/1`, stopping the SUT
  and evaluating the result of the executions as a boolean expression.
  This boolean expression can be adorned with further functions and macros
  to analyze the generated commands (via `PropCheck.aggregate/2`) or to
  inspect the history if a failure occurs (via `PropCheck.when_fail/2`).
  In the test cases, you find more examples of such adornments.

      property "run the sequential cache", [:verbose] do
        forall cmds <- commands(__MODULE__) do
          Cache.start_link(@cache_size)
          execution = run_commands(cmds)
          Cache.stop()
          (execution.result == :ok)
        end
      end

  ## Increasing the Number of Commands in a Sequence
  Sometimes issues can hide when the command sequences are short. In order to
  tease out these hidden bugs we can increase the number of commands generated
  by using the `max_size` option in our property.

        property "run the sequential cache", [max_size: 250] do
        forall cmds <- commands(__MODULE__) do
          Cache.start_link(@cache_size)
          execution = run_commands(cmds)
          Cache.stop()
          (execution.result == :ok)
        end
  """

  use PropCheck
  alias PropCheck.BasicTypes
  import PropCheck.Logger, only: [log_error: 1]

  @typedoc """
  The name of a command must be an atom.
  """
  @type command_name :: atom
  @typedoc """
  A symbolic state can be anything and appears only during phase 1.
  """
  @type symbolic_state :: any
  @typedoc """
  A dynamic state can be anything and appears only during phase 2.
  """
  @type dynamic_state :: any
  @typedoc """
  The combination of symbolic and dynamic states are required for functions
  which are used in both phases 1 and 2.
  """
  @type state_t :: symbolic_state | dynamic_state
  @typedoc """
  Each result of a symbolic call is stored in a symbolic variable. Their values
  are opaque and can only used as whole.
  """
  @type symbolic_var :: {:var, pos_integer}
  @typedoc """
  A symbolic call is the typical mfa-tuple plus the indicator `:call`.
  """
  @type symbolic_call :: {:call, module, atom, [any]}
  @typedoc """
  A value of type `command` denotes the execution of a symbolic command and
  storing its result in a symbolic variable.
  """
  @type command :: {:set, symbolic_var, symbolic_call}
  @typedoc """
  The history of command execution in phase 2 is stored in a history element.
  It contains the current dynamic state and the call to be made.
  """
  @type history_event :: {state_t, symbolic_call, {any, result_t}}
  @typedoc """
  The sequence of calls consists of state and symbolic calls.
  """
  @type state_call :: {dynamic_state, command}
  @typedoc """
  The result of the command execution. It contains either the state of the failing
  precondition, the command's return value of the failing postcondition,
  the exception values or `:ok` if everything is fine.
  """
  @type result_t :: :ok | {:pre_condition, state_t} | {:post_condition, any} |
    {:exception, any} | {:ok, any}
  # the functional command generator type, which takes a state and creates
  # a data generator from it.
  @typep gen_fun_t :: (state_t -> BasicTypes.type)
  @typep cmd_t ::
      {:args, module, String.t, atom, gen_fun_t} # |
      # {:cmd, module, String.t, gen_fun_t}
  @typep environment :: %{required(symbolic_var) => any}

  @typedoc """
  The combined result of the test. It contains the history of all executed commands,
  the final state, the final result and the environment, mapping symbolic
  vars to their actual values. Everything is fine, if `result` is `:ok`.
  """
  @type t :: %__MODULE__{
    history: [history_event],
    state: state_t,
    result: result_t,
    env: environment
  }
  defstruct [
    history: [],
    state: nil,
    result: :ok,
    env: %{}
  ]

  @doc """
  The initial state of the state machine is computed by this callback.
  """
  @callback initial_state() :: symbolic_state

  @doc """
  The optional weights for the command generation. It takes the current
  model state and returns a map of command/weight pairs. Commands,
  which are not allowed in a specific state, should be omitted, since
  a frequency of `0` is not allowed.

      def weight(state), do: %{x: 1, y: 1, a: 2, b: 2}

  """
  @callback weight(symbolic_state) :: %{required(command_name) => pos_integer}
  @optional_callbacks weight: 1

  defmacro __using__(_options) do
    quote do
      import unquote(__MODULE__)
      Module.register_attribute __MODULE__, :commands, accumulate: true
      @before_compile unquote(__MODULE__)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __all_commands__, do: @commands
    end
  end

  @known_suffixes [:pre, :post, :args, :next]
  @doc """
  Defines a new command of the model.

  Inside the command, local functions define
  * how the command is executed (`impl(...)`). This is required.
  * how the arguments in the current model state are generated (`args(state)`.
    The default is the empty list of arguments.
  * if the command is allowed in the current model state (`pre(state, arg_list) :: boolean`)
    This is `true` per default.
  * what the next state of the model is after the call (`next(old_state, arg_list, result) :: new_state`).
    The default implementation does not change the model state, sufficient for
    queries.
  * if the system under test is in the correct state after the call
    (`post(old_state, arg_list, result) :: boolean`). This is `true` in the
    default implementation.

  These local functions inside the macro are effectively callbacks to guide and
  evolve the model state.

  """
  defmacro defcommand(name, do: block) do
    pre  = String.to_atom("#{name}_pre")
    next = String.to_atom("#{name}_next")
    post = String.to_atom("#{name}_post")
    args = String.to_atom("#{name}_args")
    quote do
      def unquote(pre)(_state, _call), do: true
      def unquote(next)(state, _call, _result), do: state
      def unquote(post)(_state, _call, _res), do: true
      def unquote(args)(_state), do: []
      defoverridable [{unquote(pre), 2}, {unquote(next), 3},
        {unquote(post), 3}, {unquote(args), 1}]
      @commands Atom.to_string(unquote(name))
      unquote(Macro.postwalk(block, &rename_def_in_command(&1, name)))
    end
  end

  defp rename_def_in_command({:def, c1, [{:impl, c2, impl_args}, impl_body]}, name) do
      # Logger.error "Found impl with body #{inspect impl_body}"
    {:def, c1, [{name, c2, impl_args}, impl_body]}
  end
  defp rename_def_in_command({:def, c1, [{suffix_name, c2, args}, body]}, name)
    when suffix_name in @known_suffixes
    do
      new_name = String.to_atom("#{name}_#{suffix_name}")
      # Logger.error "Found suffix: #{new_name}"
      {:def, c1, [{new_name, c2, args}, body]}
    end
  defp rename_def_in_command(ast, _name) do
    # Logger.warn "Found ast = #{inspect ast}"
    ast
  end

  @doc """
  Generates the command list for the given module
  """
  @spec commands(module) :: BasicTypes.type()
  def commands(mod) do
    cmd_list = command_list(mod, "")
    # Logger.debug "commands:  cmd_list = #{inspect cmd_list}"
    gen_commands_proper(mod, cmd_list)
  end

  # This is taken from proper_statem.erl and achieves better shrinking
  # in case of more complex argument generators with let-constructs.
  @spec gen_commands_proper(module, [cmd_t]) :: BasicTypes.type()
  defp gen_commands_proper(mod, cmd_list) do
    let initial_state <- lazy(mod.initial_state()) do
      such_that (cmds <-
          (let list <- sized(size,
            noshrink(gen_cmd_list(size, cmd_list, mod, initial_state, 1))) do
              shrink_list(list)
          end)), when: is_valid(mod, initial_state, cmds)
    end
  end

  # Checks that the precondition holds, required for shrinking
  @spec is_valid(module, state_t, [BasicTypes.type]) :: boolean
  defp is_valid(_mod, _initial_state, []), do: true
  defp is_valid(mod, initial_state, cmds) do
    # Logger.debug "is_valid: initial=#{inspect initial_state}"
    # Logger.debug "is valid: cmds=#{inspect cmds, pretty: true}"
    initial_state == mod.initial_state() and
    is_valid(mod, initial_state, cmds, %{})
  end
  @spec is_valid(module, state_t, [BasicTypes.type], environment) :: boolean
  defp is_valid(_mod, _state, [], _env), do: true
  defp is_valid(m, state, [call | cmds], env) do
    {:set, var, c} = call
    if check_precondition(state, c) do
      replaced_call = replace_symb_vars(c, env)
      # {:call, mod, fun, args} = replaced_call
      next_state = call_next_state(state, replaced_call, var)
      is_valid(m, next_state, cmds, Map.put(env, var, var))
    else
      false
    end
  end

  # The internally used recursive generator for the command list
  @spec gen_cmd_list(pos_integer, [cmd_t], module, state_t, pos_integer) :: BasicTypes.type
  defp gen_cmd_list(0, _cmd_list, _mod, _state, _step_counter), do: exactly([])
  defp gen_cmd_list(size, cmd_list, mod, state, step_counter) do
    # Logger.debug "gen_cmd_list: cmd_list = #{inspect cmd_list}"
    cmds = create_cmds_with_args_in_state(cmd_list, mod, state)

    let call <-
      (such_that c <- cmds, when: check_precondition(state, c))
      do
        gen_result = {:var, step_counter}
        gen_state = call_next_state(state, call, gen_result)
        let cmds <- gen_cmd_list(size - 1, cmd_list, mod, gen_state, step_counter + 1) do
          [{:set, gen_result, call} | cmds]
        end
      end
  end

  defp create_cmds_with_args_in_state(cmd_list, mod, state) do
    # filter the cmds according to the weights callback (or allow all)
    valid_cmds = if :erlang.function_exported(mod, :weight, 1) do
      filter_freq_cmds(cmd_list, state, mod)
    else
      # the default frequency is unweighted commands is 1
      Enum.map(cmd_list, fn c -> {1, c} end)
    end
    # generate the arguments and put them into the frequency generator
    valid_cmds
    |> Enum.map(fn {freq, {:cmd, _mod, _f, arg_fun}} -> {freq, arg_fun.(state)} end)
    |> frequency()
  end

  # takes the list of weighted commands and filters
  # those from `cmd_list´ which have weights attached.
  defp filter_freq_cmds(cmd_list, state, mod) do
    state
    |> mod.weight()
    |> Enum.map(&find_call(&1, cmd_list, mod))
  end

  defp find_call({fun, weight}, cmd_list, mod) do
    expected = Atom.to_string(fun)

    case Enum.find(cmd_list, fn {:cmd, _m, f, _a} -> f == expected end) do
      nil -> raise "Command `#{fun}` is included in `#{inspect(mod)}.weight/1` but is not defined in that module."
      found -> {weight, found}
    end
  end

  @deprecated "Use run_commands/2 instead!"
  @doc """
  Runs the list of generated commands according to the model.

  Returns the result, the history and the final state of the model.

  Due to an internal refactoring and to achieve a common API with the `PropCheck.StateM`
  module, we changed the API for `run_commands`. This implementation infers the
  callback module from the first generated command. Usually, this will be the case,
  but we cannot rely on that.
  """
  @spec run_commands([command]) :: t
  def run_commands(commands) when length(commands) > 0 do
    {:set, _, {:call, mod, _, _}} = hd(commands)
    run_commands(mod, commands)
  end

  @doc """
  Runs the list of generated commands according to the model.

  Returns the result, the history and the final state of the model.
  """
  @spec run_commands(atom, [command]) :: t
  def run_commands(mod, commands) do
    # Logger.debug "Run commands: #{inspect commands, pretty: true}"
    initial_state = mod.initial_state()
    commands
    |> Enum.reduce(new_state(initial_state), fn

      # do nothing if a failure occurred
      _cmd, acc = %__MODULE__{result: {r, _} } when r != :ok ->
        # Logger.debug "Failed execution: r = #{inspect r}"
        acc

      # execute the next command
      cmd, acc ->
        cmd
        |> execute_cmd(acc)
        |> update_history(acc)
    end)
  end

  @spec new_state(state_t) :: %__MODULE__{}
  defp new_state(initial_state), do: %__MODULE__{state: initial_state}

  @spec execute_cmd(state_call, t) :: history_event
  defp execute_cmd({:set, v = {:var, _}, sym_c = {:call, _m, _f, _args}}, prop_state) do
    # Logger.debug "execute_cmd: symb call: #{inspect sym_c}"
    state = prop_state.state
    # Logger.debug "execute_cmd: state = #{inspect state}"
    replaced_call = replace_symb_vars(sym_c, prop_state.env)
    # Logger.debug "execute_cmd: replaced vars: #{inspect replaced_call}"
    result = if check_precondition(state, replaced_call) do
      try do
        {:call, mod, fun, args} = replaced_call
        result = apply(mod, fun, args)
        if check_postcondition(state, replaced_call, result) do
          {:ok, result}
        else
          {:post_condition, result}
        end
      rescue exc ->
        stacktrace = Exception.format_stacktrace(System.stacktrace())
        log_error "Got exception: #{inspect(exc)}\nstacktrace: #{stacktrace}"
        {:exception, {exc, stacktrace}}
      catch
        value -> {:exception, value}
        kind, value -> {:exception, {kind, value}}
      end
    else
      {:pre_condition, state}
    end
    s = case result do
      {:ok, r} ->
        # Logger.debug "result is ok, calc next state from #{inspect state}"
        # Logger.debug "replaced call is: #{inspect replaced_call}"
        new_state = call_next_state(state, replaced_call, r)
        # Logger.debug "new state is: #{inspect new_state}"
        new_state
      _ -> state
    end
    {s, replaced_call, {v, result}}
  end

  # replaces all symbolic variables of form `{:var, n}` with
  # the value in `env` (i.e. mapping of symbolic vars to values)
  @spec replace_symb_vars(
          symbolic_call | symbolic_var | [symbolic_call | symbolic_var] | any,
          environment
        ) :: symbolic_call
  defp replace_symb_vars({:call, m, f, args}, env) do
    replaced_m = replace_symb_vars(m, env)
    replaced_f = replace_symb_vars(f, env)
    replaced_args = replace_symb_vars(args, env)
    {:call, replaced_m, replaced_f, replaced_args}
  end
  defp replace_symb_vars(args, env) when is_list(args) do
    Enum.map(args, &replace_symb_vars(&1, env))
  end
  defp replace_symb_vars(v = {:var, n}, env) when is_integer(n) do
    case Map.get(env, v) do
      nil ->
        log_error "replace_symb_vars: unknown #{inspect v} in #{inspect env}"
        v
      value -> value
    end
  end
  defp replace_symb_vars(value, _env), do: value

  # updates the history and the environment
  @spec update_history(history_event, %__MODULE__{}) ::  %__MODULE__{}
  defp update_history(event = {s, _, {v, r}}, %__MODULE__{env: env, history: h}) do
    result = case r do
      {:ok, _} -> :ok
      _ -> r
    end
    value = case r do
      {:ok, val} -> val
      _ -> r
    end
    new_h = %__MODULE__{state: s,
      result: result,
      history: [event | h],
      env: Map.put(env, v, value)}
    # Logger.debug "Updated history: #{inspect h, pretty: true}"
    new_h
  end

  @spec call_next_state(state_t, symbolic_call, any) :: state_t
  defp call_next_state(state, {:call, mod, f, args}, result) do
    next_fun = (Atom.to_string(f) <> "_next")
      |> String.to_atom
    apply(mod, next_fun, [state, args, result])
  end

  @spec check_precondition(state_t, symbolic_call) :: boolean
  defp check_precondition(state, {:call, mod, f, args}) do
    pre_fun = (Atom.to_string(f) <> "_pre") |> String.to_atom
    apply(mod, pre_fun, [state, args])
  end

  @spec check_postcondition(state_t, symbolic_call, any) :: any
  defp check_postcondition(state,  {:call, mod, f, args}, result) do
    post_fun = (Atom.to_string(f) <> "_post") |> String.to_atom
    apply(mod, post_fun, [state, args, result])
  end

  @doc """
  Takes a list of generated commands and returns a list of
  mfa-tuples. This can be used for aggregation of commands.
  """
  @spec command_names(cmds :: [command]) :: [mfa]
  def command_names(cmds) do
    cmds
    |> Enum.map(fn {:set, _var, {:call, m, f, args}} ->
      # "#{m}.#{f}/#{length(args)}"
      {m, f, length(args)}
    end)
  end

  # Detects alls commands within `mod_bin_code`, i.e. all functions with the
  # same prefix and a suffix `_command` or `_args` and a prefix `_next`.
  @spec command_list(module, binary) :: [{:cmd, module, String.t, (state_t -> symbolic_call)}]
  defp command_list(mod, "") do
    mod
    |> find_commands()
    |> Enum.map(fn {cmd, _arity} ->
      args_fun = fn state ->
        # put the list of argument generators in a `fixed_list` generator
        # to prevent that the list of arguments is shortened while shrinking.
        apply(mod, String.to_atom(cmd <> "_args"), [state])
        |> fixed_list()
      end
      args = gen_call(mod, String.to_atom(cmd), args_fun)
      {:cmd, mod, cmd, args}
    end)
  end

  # Generates a function, which expects a state to create the call tuple
  # with constants for module and function and an argument generator.
  defp gen_call(mod, fun, arg_fun) when is_atom(fun) and is_function(arg_fun, 1) do
    fn state ->  {:call, mod, fun, arg_fun.(state)} end
  end

  @spec find_commands(binary|module) :: [{String.t, arity}]
  defp find_commands(mod) when is_atom(mod), do:
    mod.__all_commands__() |> Enum.map(& ({&1, 0}))

end
