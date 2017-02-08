defmodule RayScript.Translator do
  alias ESTree.Tools.Builder, as: J
  alias RayScript.Translator.{ Bitstring, Match }


  def process({:lc, _, pattern, values}) do
    {generators, filters} = Enum.split_with(values, fn
      ({:generate, _, _, _}) -> true
      _ -> false
    end)

    patterns = generators
    |> Enum.map(fn {:generate, _, pattern, _} -> 
      pattern
    end)

    generators = generators
    |> Enum.map(&process(&1))
    |> J.array_expression

    J.call_expression(
      J.member_expression(
        J.identifier("Patterns"),
        J.identifier("list_comprehension")
      ),
      [
        process({:clause, 0, patterns, [filters], [pattern]}),
        generators
      ]
    )


  end

  def process({:generate, _, pattern, list}) do   
    {patterns, _} = RayScript.Translator.Patterns.process([pattern])
    list = process(list)

    J.call_expression(
      J.member_expression(
        J.identifier("Patterns"),
        J.identifier("list_generator")
      ),
      [
        J.array_expression(patterns),
        list
      ]
    )
  end
  


  def process({:clauses, clauses}) do
    processed = Enum.map(clauses, &process(&1))

    J.call_expression(
      J.member_expression(
        J.identifier("Patterns"),
        J.identifier("defmatchgen")
      ),
      processed
    )
  end

  def process({:clause, _, pattern, guard, body}) do
    {patterns, params} = RayScript.Translator.Patterns.process(pattern)

    J.call_expression(
      J.member_expression(
        J.identifier("Patterns"),
        J.identifier("clause")
      ),
      [
        J.array_expression(patterns),
        process_body(params, body),
        process_guard(params, guard)
      ]
    )
  end

  def process({:fun, _, {:function, {:atom, _, module}, {:atom, _, name}, {:integer, _, arity}}} ) do
    handle_members(module, name, arity)
  end

  def process({:fun, _, {:function, name, arity}}) do
    J.identifier("#{name}_#{arity}")
  end

  def process({:fun, _, {:clauses, clauses}}) do
    process(clauses)
  end

  def process({:match, _, left, right}) do
    Match.match(left, right)
  end

  def process({:var, _, variable}) do
    J.identifier(variable)
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
      [J.literal("#{a}")]
    )
  end

  def process({number, _, n}) when number in [:integer, :float]  do
    J.literal(n)
  end

  def process({:char, _, n})  do
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

#  def process({:cons, _, head, {type, _, _} = tail}) when type != :cons do
#    J.call_expression(
#      J.member_expression(
#        J.array_expression([process(head)]),
#        J.identifier("concat")
#      ),
#      [process(tail)]
#    )
#  end    

  def process({:cons, _, _, _} = cons) do
    J.array_expression(handle_cons(cons, []))
  end

  def process({:bin, _, _} = bitstring) do
    Bitstring.process(bitstring)
  end

  def process({:call, _, {:atom, _, name}, params}) do
    arity = length(params)

    J.call_expression(
      J.identifier("#{name}_#{arity}"),
      Enum.map(params, &process(&1))
    )
  end

  def process({:call, _, {:remote, _, {:var, _, v}, {:atom, _, name}}, params}) do
    arity = length(params)

    J.call_expression(
      J.identifier("#{name}_#{arity}"),
      Enum.map(params, &process(&1))
    )
  end

  def process({:call, _, {:remote, _, {:atom, _, module}, {:atom, _, name}}, params}) do
    arity = length(params)
    members = handle_members(module, name, arity)

    J.call_expression(
      members,
      Enum.map(params, &process(&1))
    )
  end

  def process({:map, _, properties}) do
    properties = Enum.map(properties, &handle_map_property(&1))
    J.object_expression(properties)
  end

  def process({:op, _, op, argument}) do
    J.unary_expression(op, true, process(argument))
  end

  def process({:op, _, :rem, left, right}) do
    J.binary_expression(:%, process(left), process(right))
  end

  def process({:op, _, :and, left, right}) do
    J.binary_expression(:&&, process(left), process(right))
  end  

  def process({:op, _, :andalso, left, right}) do
    J.binary_expression(:&&, process(left), process(right))
  end

  def process({:op, _, :or, left, right}) do
    J.binary_expression(:||, process(left), process(right))
  end   

  def process({:op, _, :orelse, left, right}) do
    J.binary_expression(:||, process(left), process(right))
  end    

  def process({:op, _, op, left, right}) do
    J.binary_expression(op, process(left), process(right))
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

  defp handle_map_property({type, _, key, value}) when type in [:map_field_assoc, :map_field_exact] do
    key = process(key)
    value = process(value)
    J.property(key, value, :init, false, false, true)
  end

  defp process_guard(params, []) do
    J.function_expression(params, [], J.block_statement([
      J.return_statement(
        J.literal(true)
      )
    ]))
  end

  defp process_guard(params, guards) do
    and_guards = guards
    |> Enum.map(fn guard -> build_and_guard(guard, nil) end)

    or_guard = build_or_guard(and_guards, nil)

    J.function_expression(params, [], J.block_statement([
      J.return_statement(
        process(or_guard)
      )
    ]))
  end

  defp process_body(params, body) do
    body = Enum.map(body, &process(&1))
    |> List.flatten
    |> Enum.map(fn(x) -> J.yield_expression(x) end)
    |> J.block_statement

    J.function_expression(params, [], body, true)
  end

  defp handle_members(module, function, arity) do
    pieces = String.split(to_string(module), ".")
    pieces = pieces ++ ["#{function}_#{arity}"]
    pieces = Enum.map(pieces, fn(x) -> J.identifier(x) end)

    Enum.reduce(pieces, nil, fn(x, ast) ->
      case ast do
        nil ->
          J.member_expression(x, nil)
        %ESTree.MemberExpression{ property: nil } ->
          %{ ast | property: x }
        _ ->
          J.member_expression(ast, x)
      end
    end)
  end
  


  defp build_and_guard([], nil) do
    {:atom, 0, true}
  end

  defp build_and_guard([], value) do
    value
  end

  defp build_and_guard([filter], nil) do
    filter
  end

  defp build_and_guard([filter], value) do
    {:op, 6, :andalso, filter, value }
  end

  defp build_and_guard([filter| filters], nil) do
    {:op, 6, :andalso, filter, build_and_guard(filters, nil)}
  end

  defp build_or_guard([], nil) do
    {:atom, 0, true}
  end  

  defp build_or_guard([], value) do
    value
  end

  defp build_or_guard([filter], nil) do
    filter
  end

  defp build_or_guard([filter], value) do
    {:op, 6, :orelse, filter, value }
  end

  defp build_or_guard([filter| filters], nil) do
    {:op, 6, :orelse, filter, build_or_guard(filters, nil)}
  end  
end
