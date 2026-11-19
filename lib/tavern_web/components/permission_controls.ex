defmodule TavernWeb.PermissionControls do
  @moduledoc """
  The three-way permission control (deny, inherit, allow) that the role editor and the channel
  overwrite editor share, and the rule that turns its submitted states back into an
  `{allow, deny}` pair.

  A control the actor may not change is disabled, and a disabled radio submits nothing. So a save
  starts from the stored pair and changes only the bits that were submitted.
  """

  use Phoenix.Component

  import Bitwise
  import TavernWeb.CoreComponents, only: [icon: 1]

  alias Tavern.Chat.PermissionBits

  @states ["deny", "inherit", "allow"]

  attr :id, :string, required: true, doc: "prefix of each radio's id: `<id>-<state>`"
  attr :name, :string, required: true, doc: "the form name the chosen state submits under"
  attr :label, :string, required: true
  attr :state, :string, required: true, values: @states
  attr :disabled, :boolean, default: false
  attr :unavailable, :list, default: [], doc: "states this control never offers, shown disabled"

  @doc "Three radio buttons in one segmented control."
  def tri_state(assigns) do
    ~H"""
    <div
      role="radiogroup"
      aria-label={@label}
      class={[
        "inline-flex shrink-0 overflow-hidden rounded-md border border-base-300 bg-base-200",
        @disabled && "opacity-50"
      ]}
    >
      <label
        :for={{value, icon, tone, title} <- states()}
        title={title}
        class={[
          "relative",
          if(@disabled or value in @unavailable,
            do: "cursor-not-allowed",
            else: "cursor-pointer"
          )
        ]}
      >
        <input
          type="radio"
          id={"#{@id}-#{value}"}
          name={@name}
          value={value}
          checked={@state == value}
          disabled={@disabled or value in @unavailable}
          class="peer sr-only"
        />
        <span class={[
          "flex size-7 items-center justify-center text-base-content/40 transition-colors duration-150",
          "peer-focus-visible:ring-2 peer-focus-visible:ring-inset peer-focus-visible:ring-violet-400",
          !@disabled && value not in @unavailable && "hover:bg-base-300 hover:text-base-content",
          value in @unavailable && "opacity-30",
          tone
        ]}>
          <.icon name={icon} class="size-3.5" />
          <span class="sr-only">{title}</span>
        </span>
      </label>
    </div>
    """
  end

  @doc "The state a flag holds in an `{allow, deny}` pair: `\"allow\"`, `\"deny\"` or `\"inherit\"`."
  def state(allow, deny, flag) do
    cond do
      bit?(allow, flag) -> "allow"
      bit?(deny, flag) -> "deny"
      true -> "inherit"
    end
  end

  @doc """
  The `{allow, deny}` a save stores: `stored` with each submitted flag set to its state.
  `submitted` maps flag names to states. A name outside `flags`, or an unknown state, changes
  nothing, so input never creates atoms.
  """
  def apply_states({_allow, _deny} = stored, submitted, flags) when is_map(submitted) do
    by_name = Map.new(flags, &{to_string(&1), &1})

    Enum.reduce(submitted, stored, fn {name, state}, bits ->
      case Map.fetch(by_name, name) do
        {:ok, flag} -> set_bit(bits, PermissionBits.flag(flag), state)
        :error -> bits
      end
    end)
  end

  defp states do
    [
      {"deny", "hero-x-mark", "peer-checked:bg-rose-500 peer-checked:text-white", "Deny"},
      {"inherit", "hero-slash", "peer-checked:bg-base-300 peer-checked:text-base-content",
       "Inherit"},
      {"allow", "hero-check", "peer-checked:bg-emerald-500 peer-checked:text-white", "Allow"}
    ]
  end

  defp set_bit({allow, deny}, bit, "allow"), do: {allow ||| bit, band(deny, bnot(bit))}
  defp set_bit({allow, deny}, bit, "deny"), do: {band(allow, bnot(bit)), deny ||| bit}

  defp set_bit({allow, deny}, bit, "inherit"),
    do: {band(allow, bnot(bit)), band(deny, bnot(bit))}

  defp set_bit(bits, _bit, _state), do: bits

  defp bit?(bits, flag) do
    bit = PermissionBits.flag(flag)
    band(bits, bit) == bit
  end
end
