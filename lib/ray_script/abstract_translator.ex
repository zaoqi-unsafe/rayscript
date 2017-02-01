defmodule RayScript.AbstractTranslator do
  alias ESTree.Tools.Builder, as: J

  def translate(abstract) do
    Enum.reduce(abstract, %RayScript.Result{}, fn(ast, result) ->
      process_form(ast, result)
    end)
    |> build_module
  end

  defp build_module(result) do
    js_exports = result.export
    |> Enum.reduce([], fn({name, arity}, acc) ->
      acc ++ ["#{name}_#{arity}"]
    end)
    |> Enum.map(fn(name) ->
      J.property(J.identifier(name), J.identifier(name), :init, true)
    end)
    |> J.object_expression
    |> J.export_default_declaration

    js_body = result.body

    J.program(js_body ++ [js_exports], :module)
  end

  defp process_form({:attribute, _, :file, {file, _}}, result) do
    %{ result | file: file }
  end

  defp process_form({:attribute, _, :export, exports}, result) do
    %{ result | export: exports }
  end

  defp process_form({:function, _, name, arity, clauses}, result) do
    body = process_clauses(clauses)

    declarator = J.variable_declarator(
      J.identifier("#{name}_#{arity}"),
      body
    )

    form = J.variable_declaration([declarator], :const)

    %{ result | body: result.body ++ [form] }
  end

  defp process_form(_, result) do
    result
  end

  defp process_clauses(clauses) do
    processed = Enum.map(clauses, &process_clause(&1))

    J.call_expression(
      J.member_expression(
        J.identifier("Patterns"),
        J.identifier("defmatch")
      ),
      processed
    )
  end

  defp process_clause({:clause, _, pattern, guard, body}) do
    J.call_expression(
      J.member_expression(
        J.identifier("Patterns"),
        J.identifier("clause")
      ),
      [
        process_pattern(pattern),
        process_body(body),
        process_guard(guard),
      ]
    )
  end

  defp process_pattern(pattern) do
    J.identifier("null")
  end

  defp process_guard(guard) do
    J.identifier("null")
  end

  defp process_body(body) do
    body = Enum.map(body, &process(&1))
    |> J.block_statement

    J.function_expression([], [], body)
  end

  def process({:atom, _, nil}) do
    J.identifier("null")
  end

  def process({:atom, _, bool}) when is_boolean(bool) do
    J.literal(bool)
  end

  def process({:atom, _, a}) do
    J.call_expression(
      J.member_expression(
        J.identifier("Symbol"),
        J.identifier("for")
      ),
      [J.literal(a)]
    )
  end

  def process({number, _, n}) when number in [:integer, :float]  do
    J.literal(n)
  end

  def process({:tuple, _, items}) do
    J.new_expression(
      J.identifier("Tuple"),
      Enum.map(items, &process(&1))
    )
  end

  def process({:nil, 0}) do
    J.array_expression([])
  end

  def process({:cons, _, _, _} = cons) do
    J.array_expression(handle_cons(cons, []))
  end

  def process({:bin, _, elements}) do
    all_strings = Enum.all?(elements, fn
      {:bin_element, _, {:string, _, _}, :default, :default} -> true
      _ -> false
    end)

    if all_strings do
      process_string(elements)
    else
      elements = Enum.map(elements, &process_bin_element(&1))
      J.new_expression(
        J.identifier("BitString"),
        elements
      )
    end

  end

  def process({:call, _, {:remote, _, {:var, _, v}, {:atom, _, function}}, params}) do
    J.call_expression(
      J.member_expression(
        J.identifier(v),
        J.identifier(function)
      ),
      Enum.map(params, &process(&1))
    )
  end

  def process({:call, _, {:remote, _, {:atom, _, module}, {:atom, _, function}}, params}) do
    pieces = String.split(inspect(module), ".")
    pieces = pieces ++ [function]
    pieces = Enum.map(pieces, fn(x) -> J.identifier(x) end)

    members = Enum.reduce(pieces, nil, fn(x, ast) ->
      case ast do
        nil ->
          J.member_expression(x, nil)
        %ESTree.MemberExpression{ property: nil } ->
          %{ ast | property: x }
        _ ->
          J.member_expression(ast, x)
      end
    end)


    J.call_expression(
      members,
      Enum.map(params, &process(&1))
    )
  end

  def process({:fun, _, {:clauses, clauses}}) do
    process_clauses(clauses)
  end

  def process(_) do
    J.identifier("null")
  end

  defp handle_cons({:cons, _, head, {nil, _}}, list) do
    list ++ [process(head)]
  end

  defp handle_cons({:cons, _, head, tail}, list) do
    list ++ [process(head)] ++ handle_cons(tail, list)
  end

  defp process_string(elements) do
    Enum.reduce(elements, [], fn({:bin_element, _, {:string, _, str}, _, _}, acc) ->
      acc ++ [str]
    end)
    |> Enum.join("")
    |> J.literal
  end

  defp process_bin_element({:bin_element, _, {:string, _, str}, :default, [attr]}) when attr in [:utf8, :utf16, :utf32] do

    J.call_expression(
      J.member_expression(
        J.identifier("BitString"),
        J.identifier(attr)
      ),
      [
        J.literal(str)
      ]
    )
  end

  defp process_bin_element({:bin_element, _, {type, _, _} = value, :default, :default}) do
    type = if type == :string, do: :binary, else: type

    J.call_expression(
      J.member_expression(
        J.identifier("BitString"),
        J.identifier(type)
      ),
      [
        process(value)
      ]
    )
  end

  defp process_bin_element({:bin_element, _, {_, _, _} = value, {type, _, size}, :default}) do
    inner = J.call_expression(
      J.member_expression(
        J.identifier("BitString"),
        J.identifier(type)
      ),
      [
        process(value)
      ]
    )

    J.call_expression(
      J.member_expression(
        J.identifier("BitString"),
        J.identifier(:size)
      ),
      [
        inner,
        J.literal(size)
      ]
    )
  end

  defp process_bin_element({:bin_element, _, {:var, _, var_name}, :default, attrs}) do
    Enum.reduce(attrs, J.identifier(var_name), fn(attr, x) ->
      J.call_expression(
        J.member_expression(
          J.identifier("BitString"),
          J.identifier(attr)
        ),
        [
          x
        ]
      )
    end)
  end

  defp process_bin_element({:bin_element, _, {type, _, _} = value, :default, attrs}) do
    inner = J.call_expression(
      J.member_expression(
        J.identifier("BitString"),
        J.identifier(type)
      ),
      [
        process(value)
      ]
    )

    Enum.reduce(attrs, inner, fn(attr, x) ->
      J.call_expression(
        J.member_expression(
          J.identifier("BitString"),
          J.identifier(attr)
        ),
        [
          x
        ]
      )
    end)
  end


  defp process_bin_element({:bin_element, _, {_, _, _} = value, {type, _, size}, attrs}) do
    inner = J.call_expression(
      J.member_expression(
        J.identifier("BitString"),
        J.identifier(type)
      ),
      [
        process(value)
      ]
    )

    size = J.call_expression(
      J.member_expression(
        J.identifier("BitString"),
        J.identifier(:size)
      ),
      [
        inner,
        J.literal(size)
      ]
    )

    Enum.reduce(attrs, size, fn(attr, x) ->
      J.call_expression(
        J.member_expression(
          J.identifier("BitString"),
          J.identifier(attr)
        ),
        [
          x
        ]
      )
    end)
  end
end
