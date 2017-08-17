defmodule Croma.Struct do
  @moduledoc """
  Utility module to define structs and some helper functions.

  Using this module requires to prepare modules that represent each struct field.
  Each of per-field module must provide the following members:

  - required: `@type t`
  - required: `@spec valid?(term) :: boolean`
  - optional: `@spec default() :: t`

  Some helpers for defining such per-field type modules are available.

  - Wrappers of built-in types such as `Croma.String`, `Croma.Integer`, etc.
  - Utility modules such as `Croma.SubtypeOfString` to define "subtypes" of existing types.
  - Ad-hoc module generators defined in `Croma.TypeGen`.
  - This module, `Croma.Struct` itself for nested structs.
      - `:recursive_new?` option may come in handy when constructing a nested struct. See the section below.

  To define a struct, `use` this module with a keyword list:

      defmodule S do
        use Croma.Struct, fields: [field1_name: Field1Module, field2_name: Field2Module]
      end

  Then the above code is converted to `defstruct` along with `@type t`.

  This module also generates the following functions.

  - `@spec valid?(term) :: boolean`
  - `@spec new(Dict.t) :: Croma.Result.t(t)`
  - `@spec new!(Dict.t) :: t`
  - `@spec update(t, Dict.t) :: Croma.Result.t(t)`
  - `@spec update!(t, Dict.t) :: t`

  ## Examples
      iex> defmodule I do
      ...>   @type t :: integer
      ...>   def validate(i) when is_integer(i), do: {:ok, i}
      ...>   def validate(_), do: {:error, {:invalid_value, [__MODULE__]}}
      ...>   def default(), do: 0
      ...> end

      ...> defmodule S do
      ...>   use Croma.Struct, fields: [i: I]
      ...> end

      ...> S.new(%{i: 5})
      {:ok, %S{i: 5}}

      ...> S.valid?(%S{i: "not_an_integer"})
      false

      ...> {:ok, s} = S.new(%{})
      {:ok, %S{i: 0}}

      ...> S.update(s, [i: 2])
      {:ok, %S{i: 2}}

      ...> S.update(s, %{"i" => "not_an_integer"})
      {:error, {:invalid_value, [S, I]}}

  ## Naming convention of field names (case of identifiers)

  When working with structured data (e.g. JSON) from systems with different naming conventions,
  it's convenient to adjust the names to your favorite convention in this layer.
  You can specify the acceptable naming schemes of data structures to be validated
  by `:accept_case` option of `use Croma.Struct`.

  - `nil` (default): Accepts only the given field names.
  - `:lower_camel`: Accepts both the given field names and their lower camel variants.
  - `:upper_camel`: Accepts both the given field names and their upper camel variants.
  - `:snake`: Accepts both the given field names and their snake cased variants.
  - `:capital`: Accepts both the given field names and their variants where all characters are capital.

  ## Nested struct and `:recursive_new?`

  When you make an instance of nested struct defined using `Croma.Struct`,
  it's convenient to recursively calling `new/1` for each sub-structs,
  so that whole data structure can be generated by just one invocation of `new/1` of the root struct.

  `:recursive_new?` option can be set to `true` for such case.

      iex> defmodule Leaf do
      ...>   use Croma.Struct, fields: [ns: Croma.TypeGen.nilable(Croma.String)]
      ...> end

      ...> defmodule Branch do
      ...>   use Croma.Struct, fields: [l: Leaf], recursive_new?: true
      ...> end

      ...> defmodule Root do
      ...>   use Croma.Struct, fields: [b: Branch], recursive_new?: true
      ...> end

      ...> Root.new(%{})
      {:ok, %Root{b: %Branch{l: %Leaf{ns: nil}}}}

  Note that if a field is missing, complementary functions will be called in order of
  `default/0` then `new/1` (with empty map as input).

  Also, if a field has an invalid value, `new/1` will be called with that value as input.

  ## Limitation

  - If you want to validate your struct with a rule that spans multiple fields
    (e.g. `f1` and `f2` must be "both `nil`" or "both `integer`"),
    you have to manually define `@type t`, `valid?/1`, etc.
  """

  import Croma.Defun
  require Croma.Result, as: R

  @doc false
  def field_type_pairs(fields) do
    Enum.map(fields, fn {key, mod} ->
      {key, quote do: unquote(mod).t}
    end)
  end

  @doc false
  def fields_with_accept_case(fields, accept_case) do
    f = case accept_case do
      nil          -> fn a -> a end
      :snake       -> &Macro.underscore/1
      :lower_camel -> &lower_camelize/1
      :upper_camel -> &Macro.camelize/1
      :capital     -> &String.upcase/1
      _            -> raise ":accept_case option must be :lower_camel, :upper_camel, :snake or :capital"
    end
    fields2 = Enum.map(fields, fn {key, mod} ->
      key2 = Atom.to_string(key) |> f.() |> String.to_atom()
      {key, Enum.uniq([key, key2]), mod}
    end)
    accepted_keys = Enum.flat_map(fields2, fn {_, keys, _} -> keys end)
    if length(accepted_keys) != length(Enum.uniq(accepted_keys)) do
      raise "field names are not unique"
    end
    fields2
  end

  defp lower_camelize(s) do
    if byte_size(s) == 0 do
      ""
    else
      c = Macro.camelize(s)
      String.downcase(String.first(c)) <> String.slice(c, 1..-1)
    end
  end

  @doc false
  def new_impl(mod, struct_fields, dict, recursive?) do
    Enum.map(struct_fields, fn {field, fields_to_fetch, mod} ->
      case dict_fetch2(dict, fields_to_fetch) do
        {:ok, v} -> evaluate_existing_field(mod, v, recursive?)
        :error   -> evaluate_non_existing_field(mod, recursive?)
      end
      |> R.map(&{field, &1})
    end)
    |> R.sequence()
    |> case do
      {:ok   , kvs   } -> {:ok, struct(mod, kvs)}
      {:error, reason} -> {:error, R.ErrorReason.add_context(reason, mod)}
    end
  end

  defp evaluate_existing_field(mod, value, false), do: Croma.Validation.call_validate1(mod, value)
  defp evaluate_existing_field(mod, value, true ), do: Croma.Validation.call_validate1(mod, value) |> R.or_else(try_new(mod, value, :invalid_value))

  defp evaluate_non_existing_field(mod, false), do: try_default(mod)
  defp evaluate_non_existing_field(mod, true ), do: try_default(mod) |> R.or_else(try_new(mod, %{}, :value_missing))

  defp try_new(mod, value, reason) do
    try do
      mod.new(value)
    rescue
      _ -> {:error, {reason, [mod]}}
    end
  end

  defp try_default(mod) do
    try do
      {:ok, mod.default()}
    rescue
      _ -> {:error, {:value_missing, [mod]}}
    end
  end

  @doc false
  def validate_impl(mod, struct_fields, dict) when is_list(dict) or is_map(dict) do
    kv_results = Enum.map(struct_fields, fn {field, fields_to_fetch, mod} ->
      v =
        case dict_fetch2(dict, fields_to_fetch) do
          {:ok, v} -> v
          :error   -> nil
        end
      Croma.Validation.call_validate1(mod, v) |> R.map(&{field, &1})
    end)
    case R.sequence(kv_results) do
      {:ok   , kvs   } -> {:ok, struct(mod, kvs)}
      {:error, reason} -> {:error, R.ErrorReason.add_context(reason, mod)}
    end
  end
  def validate_impl(mod, _, _), do: {:error, {:invalid_value, [mod]}}

  @doc false
  def update_impl(s, mod, struct_fields, dict) when is_list(dict) or is_map(dict) do
    kv_results = Enum.map(struct_fields, fn {field, fields_to_fetch, mod} ->
      case dict_fetch2(dict, fields_to_fetch) do
        {:ok, v} -> Croma.Validation.call_validate1(mod, v) |> R.map(&{field, &1})
        :error   -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    case R.sequence(kv_results) do
      {:ok   , kvs   } -> {:ok, struct(s, kvs)}
      {:error, reason} -> {:error, R.ErrorReason.add_context(reason, mod)}
    end
  end

  defp dict_fetch2(dict, keys) do
    case keys do
      [key]        -> dict_fetch2_impl(dict, key)
      [key1, key2] ->
        case dict_fetch2_impl(dict, key1) do
          {:ok, _} = r -> r
          :error       -> dict_fetch2_impl(dict, key2)
        end
    end
  end
  defp dict_fetch2_impl(dict, key) when is_list(dict) do
    key_str = Atom.to_string(key)
    Enum.find_value(dict, :error, fn
      {k, v} when k == key or k == key_str -> {:ok, v}
      _                                    -> nil
    end)
  end
  defp dict_fetch2_impl(dict, key) when is_map(dict) do
    case Map.fetch(dict, key) do
      {:ok, _} = r -> r
      :error       -> Map.fetch(dict, Atom.to_string(key))
    end
  end

  defmacro __using__(opts) do
    quote bind_quoted: [fields: opts[:fields], accept_case: opts[:accept_case], recursive_new?: opts[:recursive_new?]] do
      defstruct Keyword.keys(fields)
      @type t :: %unquote(__MODULE__){unquote_splicing(Croma.Struct.field_type_pairs(fields))}

      @croma_struct_fields Croma.Struct.fields_with_accept_case(fields, accept_case)

      if recursive_new? do
        @doc """
        Creates a new instance of #{inspect(__MODULE__)} by using the given `dict`.

        Returns `{:ok, valid_struct}` or `{:error, reason}`.

        The values in the `dict` are validated by each field's `validate/1` function.
        If the value was invalid, it will be passed to `new/1` of the field

        For missing fields, followings will be tried:
        - `default/0` of each field type
        - `new/1` of each field type, with empty map as input
        """
        defun new(dict :: Dict.t) :: R.t(t) do
          Croma.Struct.new_impl(__MODULE__, @croma_struct_fields, dict, true)
        end
      else
        @doc """
        Creates a new instance of #{inspect(__MODULE__)} by using the given `dict`.

        For missing fields, `default/0` of each field type will be used.

        Returns `{:ok, valid_struct}` or `{:error, reason}`.
        The values in the `dict` are validated by each field's `validate/1` function.
        """
        defun new(dict :: Dict.t) :: R.t(t) do
          Croma.Struct.new_impl(__MODULE__, @croma_struct_fields, dict, false)
        end
      end

      @doc """
      A variant of `new/1` which returns `t` or raise if validation fails.

      In other words, `new/1` followed by `Croma.Result.get!/1`.
      """
      defun new!(dict :: Dict.t) :: t do
        new(dict) |> R.get!()
      end

      Enum.each(fields, fn {name, mod} ->
        @doc """
        Type-aware getter for #{name}.
        """
        @spec unquote(name)(t) :: unquote(mod).t
        def unquote(name)(%__MODULE__{unquote(name) => field}) do
          field
        end

        @doc """
        Type-aware setter for #{name}.
        """
        @spec unquote(name)(t, unquote(mod).t) :: t
        def unquote(name)(s, field) do
          %__MODULE__{s | unquote(name) => field}
        end
      end)

      @doc """
      Checks if the given value belongs to `t:t/0` or not.
      """
      defun valid?(value :: term) :: boolean do
        %__MODULE__{} = s ->
          Enum.all?(@croma_struct_fields, fn {field, _fields_to_fetch, mod} ->
            Croma.Validation.call_valid1(mod, Map.get(s, field))
          end)
        _ -> false
      end

      @doc """
      Checks that the given `dict` is valid or not by using each field's `validate/1` function.
      Returns `{:ok, valid_struct}` or `{:error, reason}`.
      """
      defun validate(dict :: Dict.t) :: R.t(t) do
        Croma.Struct.validate_impl(__MODULE__, @croma_struct_fields, dict)
      end

      @doc """
      A variant of `validate/1` which returns `t` or raise if validation fails.
      In other words, `validate/1` followed by `Croma.Result.get!/1`.
      """
      defun validate!(dict :: Dict.t) :: t do
        validate(dict) |> R.get!()
      end

      @doc """
      Updates an existing instance of #{inspect(__MODULE__)} with the given `dict`.
      The values in the `dict` are validated by each field's `validate/1` function.
      Returns `{:ok, valid_struct}` or `{:error, reason}`.
      """
      defun update(%__MODULE__{} = s :: t, dict :: Dict.t) :: R.t(t) do
        Croma.Struct.update_impl(s, __MODULE__, @croma_struct_fields, dict)
      end

      @doc """
      A variant of `update/2` which returns `t` or raise if validation fails.
      In other words, `update/2` followed by `Croma.Result.get!/1`.
      """
      defun update!(s :: t, dict :: Dict.t) :: t do
        update(s, dict) |> R.get!()
      end
    end
  end
end
