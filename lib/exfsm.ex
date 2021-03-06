defmodule ExFSM do
  @type fsm_spec :: %{{state_name :: atom, event_name :: atom} => {exfsm_module :: atom,[dest_statename :: atom]}}
  @moduledoc """
  After `use ExFSM` : define FSM transition handler with `deftrans fromstate({action_name,params},state)`.
  A function `fsm` will be created returning a map of the `fsm_spec` describing the fsm. 
  
  Destination states are found with AST introspection, if the `{:next_state,xxx,xxx}` is defined
  outside the `deftrans/2` function, you have to define them manually defining a `@to` attribute.

  For instance : 

      iex> defmodule Elixir.Door do
      ...>   use ExFSM
      ...>   deftrans closed({:open_door,_params},state) do
      ...>     {:next_state,:opened,state}
      ...>   end
      ...>   @to [:closed]
      ...>   deftrans opened({:close_door,_params},state) do
      ...>     then = :closed
      ...>     {:next_state,then,state}
      ...>   end
      ...> end
      ...> Door.fsm
      %{
        {:closed,:open_door}=>{Door,[:opened]},
        {:opened,:close_door}=>{Door,[:closed]}
      }
  """

  defmacro __using__(_opts) do
    quote do
      import ExFSM
      @fsm %{}
      @to nil
      @before_compile ExFSM
    end
  end
  defmacro __before_compile__(_env) do
    quote do
      def fsm, do: @fsm
    end
  end

  @doc """
    Define a function of type `transition` describing a state and its
    transition. The function name is the state name, the transition is the
    first argument. A state object can be modified and is the second argument.

        deftrans opened({:close_door,_params},state) do
          {:next_state,:closed,state}
        end
  """
  @type transition :: (({event_name :: atom, event_param :: any},state :: any) -> {:next_state,event_name :: atom,state :: any})
  defmacro deftrans({state,_meta,[{trans,_param}|_rest]}=signature, body_block) do
    quote do
      @fsm Dict.put(@fsm,{unquote(state),unquote(trans)},{__MODULE__,@to || unquote(Enum.uniq(find_nextstates(body_block[:do])))})
      def unquote(signature), do: unquote(body_block[:do])
      @to nil
    end  
  end

  defp find_nextstates({:{},_,[:next_state,state|_]}) when is_atom(state), do: [state]
  defp find_nextstates({_,_,asts}), do: find_nextstates(asts)
  defp find_nextstates({_,asts}), do: find_nextstates(asts)
  defp find_nextstates(asts) when is_list(asts), do: Enum.flat_map(asts,&find_nextstates/1)
  defp find_nextstates(_), do: []
end

defmodule ExFSM.Machine do
  @moduledoc """
  Module to simply use FSMs defined with ExFSM : 

  - `ExFSM.Machine.fsm/1` merge fsm from multiple handlers (see `ExFSM` to see how to define one).
  - `ExFSM.Machine.event/2` allows you to execute the correct handler from a state and action

  Define a structure implementing `ExFSM.Machine.State` in order to
  define how to extract handlers and state_name from state, and how
  to apply state_name change. Then use `ExFSM.Machine.event/2` in order
  to execute transition.

      iex> defmodule Elixir.Door1 do
      ...>   use ExFSM
      ...>   deftrans closed({:open_door,_},s) do {:next_state,:opened,s} end
      ...> end
      ...> defmodule Elixir.Door2 do
      ...>   use ExFSM
      ...>   deftrans opened({:close_door,_},s) do {:next_state,:closed,s} end
      ...> end
      ...> ExFSM.Machine.fsm([Door1,Door2])
      %{
        {:closed,:open_door}=>{Door1,[:opened]},
        {:opened,:close_door}=>{Door2,[:closed]}
      }
      iex> defmodule Elixir.DoorState, do: defstruct(handlers: [], state: nil)
      ...> defimpl ExFSM.Machine.State, for: DoorState do
      ...>   def handlers(d) do d.handlers end
      ...>   def state_name(d) do d.state end
      ...>   def set_state_name(d,name) do %{d|state: name} end
      ...> end
      ...> %{__struct__: DoorState,handlers: [Door1,Door2],state: :closed} 
      ...>   |> ExFSM.Machine.event({:open_door,nil}) 
      {:next_state,%{__struct__: DoorState,handlers: [Door1,Door2],state: :opened}}

  """
  defprotocol State do
    @doc "retrieve current state handlers from state object, return [Handler1,Handler2]"
    def handlers(state)
    @doc "retrieve current state name from state object"
    def state_name(state)
    @doc "set new state name"
    def set_state_name(state,state_name)
  end

  @doc "return the FSM as a map of transitions %{{state,action}=>{handler,[dest_states]}} based on handlers"
  @spec fsm([exfsm_module :: atom]) :: ExFSM.fsm_spec
  def fsm(handlers) when is_list(handlers), do:
    (handlers |> Enum.map(&(&1.fsm)) |> Enum.concat |> Enum.into(%{}))
  def fsm(state), do:
    fsm(State.handlers(state))

  @doc "find the ExFSM Module from the list `handlers` implementing the event `action` from `state_name`"
  @spec find_handler({state_name::atom,event_name::atom},[exfsm_module :: atom]) :: exfsm_module :: atom
  def find_handler({state_name,action},handlers) when is_list(handlers) do
    case Dict.get(fsm(handlers),{state_name,action}) do
      {handler,_}-> handler
      _ -> nil
    end
  end
  @doc "same as `find_handler/2` but using a 'meta' state implementing `ExFSM.Machine.State`"
  def find_handler({state,action}), do:
    find_handler({State.state_name(state),action},State.handlers(state))

  @doc "Meta application of the transition function, using `find_handler/2` to find the module implementing it."
  @type meta_event_reply :: {:next_state,ExFSM.Machine.State.t} | {:next_state,ExFSM.Machine.State.t,timeout :: integer} | {:error,:illegal_action}
  @spec event(ExFSM.Machine.State.t,{event_name :: atom, event_params :: any}) :: meta_event_reply
  def event(state,{action,params}) do
    case find_handler({state,action}) do
      nil -> {:error,:illegal_action}
      handler ->
        case apply(handler,State.state_name(state),[{action,params},state]) do
          {:next_state,state_name,state,timeout} -> {:next_state,State.set_state_name(state,state_name),timeout}
          {:next_state,state_name,state} -> {:next_state,State.set_state_name(state,state_name)}
          other -> other
        end
    end
  end

  @spec available_actions(ExFSM.Machine.State.t) :: [action_name :: atom]
  def available_actions(state) do
    ExFSM.Machine.fsm(state) 
    |> Enum.filter(fn {{from,_},_}->from==State.state_name(state) end)
    |> Enum.map(fn {{_,action},_}->action end)
  end

  @spec action_available?(ExFSM.Machine.State.t,action_name :: atom) :: boolean
  def action_available?(state,action) do
    action in available_actions(state) 
  end
end
