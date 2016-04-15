defmodule Croma.Defun do
  @moduledoc """
  Module that provides `Croma.Defun.defun/2` macro.
  """

  @doc """
  Defines a function together with its typespec.
  This provides a lighter-weight syntax for functions with type specifications and functions with multiple clauses.

  ## Example
  The following examples assume that `Croma.Defun` is imported
  (you can import it by `use Croma`).

      defun f(a :: integer, b :: String.t) :: String.t do
        "\#{a} \#{b}"
      end

  The code above is expanded to the following function definition.

      @spec f(integer, String.t) :: String.t
      def f(a, b) do
        "\#{a} \#{b}"
      end

  Function with multiple clauses and/or pattern matching on parameters can be defined
  in the same way as `case do ... end`:

      defun dumbmap(as :: [a], f :: (a -> b)) :: [b] when a: term, b: term do
        ([]     , _) -> []
        ([h | t], f) -> [f.(h) | dumbmap(t, f)]
      end

  is converted to

      @spec dumbmap([a], (a -> b)) :: [b] when a: term, b: term
      def dumbmap(as, f)
      def dumbmap([], _) do
        []
      end
      def dumbmap([h | t], f) do
        [f.(h) | dumbmap(t, f)]
      end

  ## Pattern matching on function parameter and omitting parameter's type
  If you omit parameter's type, its type is infered from the parameter's expression.
  Suppose we have the following function:

      defun f(%MyStruct{field1: field1, field2: field2}) :: String.t do
        "\#{field1} \#{field2}"
      end

  then the parameter type becomes `MyStruct.t`.

      @spec f(MyStruct.t) :: String.t
      def f(a1)
      def f(%MyStruct{field1: field1, field2: field2}) do
        "\#{field1} \#{field2}"
      end

  ## Generating guards from argument types
  Simple guard expressions can be generated by `defun/2` using `g[type]` syntax.
  For example,

      defun f(s :: g[String.t], i :: g[integer]) :: String.t do
        "\#{s} \#{i}"
      end

  is converted to the following function with `when is_integer(i)` guard.

      @spec f(String.t, integer) :: String.t
      def f(s, i)
      def f(s, i) when is_binary(s) and is_integer(i) do
        "\#{s} \#{i}"
      end

  For supported types of guard-generation please refer to the source code of `Croma.Guard.make/3`.

  Guard generation can be disabled by setting application config during compilation.
  For example, by putting the following into `config/config.exs`,

      config :croma, [
        defun_generate_guard: false
      ]

  then `g[String.t]` becomes semantically the same as `String.t`.

  ## Validating arguments based on their types
  You can instrument check of preconditions on arguments by specifying argument's type as `v[type]`.
  For instance,

      defmodule MyString do
        use Croma.SubtypeOfString, pattern: ~r/^foo|bar$/
      end

      defun f(s :: v[MyString.t]) :: atom do
        String.to_atom(s)
      end

  becomes the following function definition that calls `validate/1` at the top of its body:

      @spec f(MyString.t) :: atom
      def f(s)
      def f(s) do
        s = case MyString.validate(s) do
          {:ok   , value } -> value
          {:error, reason} -> raise "..."
        end
        String.to_atom(s)
      end

  The generated code assumes that `validate/1` function is defined in the same module as the specified type.

  Generating validation of arguments can be disabled by setting application config during compilation.

      config :croma, [
        defun_generate_validation: false
      ]

  ## Known limitations
  - Overloaded typespecs are not supported.
  - Guard generation and validation are not allowed to be used with multi-clause syntax.
  - Using unquote fragment in parameter list is not fully supported.
  - `try` block is not implicitly started in body of `defun`, in contrast to `def`.
  """
  defmacro defun({:::, _, [fun, ret_type]}, [do: block]) do
    defun_impl(:def, fun, ret_type, [], block, __CALLER__)
  end
  defmacro defun({:when, _, [{:::, _, [fun, ret_type]}, type_params]}, [do: block]) do
    defun_impl(:def, fun, ret_type, type_params, block, __CALLER__)
  end

  @doc """
  Defines a private function together with its typespec.
  See `defun/2` for usage of this macro.
  """
  defmacro defunp({:::, _, [fun, ret_type]}, [do: block]) do
    defun_impl(:defp, fun, ret_type, [], block, __CALLER__)
  end
  defmacro defunp({:when, _, [{:::, _, [fun, ret_type]}, type_params]}, [do: block]) do
    defun_impl(:defp, fun, ret_type, type_params, block, __CALLER__)
  end

  @doc """
  Defines a unit-testable private function together with its typespec.
  See `defun/2` for usage of this macro.
  See also `Croma.Defpt.defpt/2`.
  """
  defmacro defunpt({:::, _, [fun, ret_type]}, [do: block]) do
    defun_impl(:defpt, fun, ret_type, [], block, __CALLER__)
  end
  defmacro defunpt({:when, _, [{:::, _, [fun, ret_type]}, type_params]}, [do: block]) do
    defun_impl(:defpt, fun, ret_type, type_params, block, __CALLER__)
  end

  defmodule Arg do
    @moduledoc false
    defstruct [:arg_expr, :type, :default, :guard?, :validate?]

    def new({:\\, _, [inner_expr, default]}) do
      %__MODULE__{new(inner_expr) | default: {:some, default}}
    end
    def new({:::, _, [arg_expr, type_expr]}) do
      {type_expr2, g_used?, v_used?} = extract_guard_and_validate(type_expr)
      guard?    = g_used? and Application.get_env(:croma, :defun_generate_guard, true)
      validate? = v_used? and Application.get_env(:croma, :defun_generate_validation, true)
      %__MODULE__{arg_expr: arg_expr, type: type_expr2, default: :none, guard?: guard?, validate?: validate?}
    end
    def new(arg_expr) do
      %__MODULE__{arg_expr: arg_expr, type: infer_type(arg_expr), default: :none, guard?: false, validate?: false}
    end

    defp extract_guard_and_validate({{:., _, [Access, :get]}, _, [{:g, _, _}, inner_expr]}), do: {inner_expr, true , false}
    defp extract_guard_and_validate({{:., _, [Access, :get]}, _, [{:v, _, _}, inner_expr]}), do: {inner_expr, false, true }
    defp extract_guard_and_validate(type_expr                                             ), do: {type_expr , false, false}

    defp infer_type(arg_expr) do
      case arg_expr do
        {:=, _, [{_, _, c}, inner]} when is_atom(c) -> infer_type(inner)
        {:=, _, [inner, {_, _, c}]} when is_atom(c) -> infer_type(inner)
        {_name, _, c}               when is_atom(c) -> quote do: any
        {:{}, _, elements}                          -> quote do: {unquote_splicing(Enum.map(elements, &infer_type/1))}
        {elem1, elem2}                              -> quote do: {unquote(infer_type(elem1)), unquote(infer_type(elem2))}
        l when is_list(l)                           -> quote do: []
        {:%{}, _, _}                                -> quote do: %{}
        {:%, _, [module_alias, _]}                  -> quote do: unquote(module_alias).t
        expr when is_atom(expr)                     -> expr
        expr when is_integer(expr)                  -> quote do: integer
        expr when is_float(expr)                    -> quote do: float
        expr when is_binary(expr)                   -> quote do: String.t
      end
    end

    def as_var(%Arg{arg_expr: arg_expr}) do
      case arg_expr do
        {name, _, context}               when is_atom(context) -> Macro.var(name, nil)
        {:=, _, [{name, _, context}, _]} when is_atom(context) -> Macro.var(name, nil)
        {:=, _, [_, {name, _, context}]} when is_atom(context) -> Macro.var(name, nil)
        _ -> nil
      end
    end
    def as_var!(%Arg{arg_expr: arg_expr} = arg) do
      as_var(arg) || raise "parameter `#{Macro.to_string(arg_expr)}` is not a var"
    end

    def guard_expr(%Arg{guard?: false}, _), do: nil
    def guard_expr(%Arg{guard?: true, type: type} = arg, caller) do
      Croma.Guard.make(type, as_var!(arg), caller)
    end

    def validation_expr(%Arg{validate?: false}), do: nil
    def validation_expr(%Arg{validate?: true, type: type} = arg) do
      Croma.Validation.make(type, as_var!(arg))
    end
  end

  defp defun_impl(def_or_defp, {fname, env, args0}, ret_type, type_params, block, caller) do
    args = case args0 do
      context when is_atom(context) -> [] # function definition without parameter list
      _ -> Enum.map(args0, &Arg.new/1)
    end
    spec = typespec(fname, env, args, ret_type, type_params)
    bodyless = bodyless_function(def_or_defp, fname, env, args)
    fundef = function_definition(def_or_defp, fname, env, args, block, caller)
    {:__block__, [], [spec, bodyless, fundef]}
  end

  defp typespec(fname, env, args, ret_type, type_params) do
    arg_types = Enum.map(args, &(&1.type))
    func_with_return_type = {:::, [], [{fname, [], arg_types}, ret_type]}
    spec_expr = case type_params do
      [] -> func_with_return_type
      _  -> {:when, [], [func_with_return_type, type_params]}
    end
    {:@, env, [
        {:spec, [], [spec_expr]}
      ]}
  end

  defp bodyless_function(def_or_defp, fname, env, args) do
    arg_exprs = Enum.with_index(args) |> Enum.map(fn {%Arg{default: default} = arg, index} ->
      var = Arg.as_var(arg) || Macro.var(:"a#{Integer.to_string(index)}", nil)
      case default do
        :none            -> var
        {:some, default} -> {:\\, [], [var, default]}
      end
    end)
    {def_or_defp, env, [{fname, env, arg_exprs}]}
  end

  defp function_definition(def_or_defp, fname, env, args, block, caller) do
    defs = case block do
      {:__block__, _, multiple_defs} -> multiple_defs
      single_def                     -> List.wrap(single_def)
    end
    if !Enum.empty?(defs) and Enum.all?(defs, &pattern_match_expr?/1) do
      if Enum.any?(args, &(&1.guard?   )), do: raise "guard generation cannot be used with clause syntax"
      if Enum.any?(args, &(&1.validate?)), do: raise "argument validation cannot be used with clause syntax"
      clause_defs = Enum.map(defs, &to_clause_definition(def_or_defp, fname, &1))
      {:__block__, env, clause_defs}
    else
      call_expr = call_expr_with_guard(fname, env, args, caller)
      body = body_with_validation(args, block)
      {def_or_defp, env, [call_expr, [do: body]]}
    end
  end

  defp pattern_match_expr?({:->, _, _}), do: true
  defp pattern_match_expr?(_          ), do: false

  defp to_clause_definition(def_or_defp, fname, {:->, env, [args, block]}) do
    case args do
      [{:when, _, when_args}] ->
        fargs = Enum.take(when_args, length(when_args) - 1)
        guards = List.last(when_args)
        {def_or_defp, env, [{:when, [], [{fname, [], fargs}, guards]}, [do: block]]}
      _ ->
        {def_or_defp, env, [{fname, env, args}, [do: block]]}
    end
  end

  defp call_expr_with_guard(fname, env, args, caller) do
    arg_exprs = Enum.map(args, &(&1.arg_expr)) |> reset_hygienic_counter
    guard_exprs = Enum.map(args, &Arg.guard_expr(&1, caller)) |> Enum.reject(&is_nil/1)
    if Enum.empty?(guard_exprs) do
      {fname, env, arg_exprs}
    else
      combined_guard_expr = Enum.reduce(guard_exprs, fn(expr, acc) -> {:and, env, [acc, expr]} end)
      {:when, env, [{fname, env, arg_exprs}, combined_guard_expr]}
    end
  end

  defp body_with_validation(args, block) do
    exprs = case reset_hygienic_counter(block) do
      {:__block__, _, exprs} -> exprs
      nil                    -> []
      expr                   -> [expr]
    end
    validation_exprs = Enum.map(args, &Arg.validation_expr/1) |> Enum.reject(&is_nil/1)
    case validation_exprs ++ exprs do
      []     -> nil
      [expr] -> expr
      exprs  -> {:__block__, [], exprs}
    end
  end

  defp reset_hygienic_counter(ast) do
    Macro.prewalk(ast, fn
      {name, meta, context} when is_atom(context) -> {name, Keyword.delete(meta, :counter), nil}
      t -> t
    end)
  end
end
