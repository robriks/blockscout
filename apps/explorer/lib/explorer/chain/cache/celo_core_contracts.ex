defmodule Explorer.Chain.Cache.CeloCoreContracts do
  @moduledoc """
  Cache for Celo core contract addresses.

  This module operates with a `CELO_CORE_CONTRACTS` environment variable, which
  contains the JSON map of core contract addresses on the Celo network. The
  module provides functions to fetch the addresses of core contracts at a given
  block. Additionally, it provides a function to obtain the state of a specific
  contract by fetching the latest event for the contract at a given block.

  For details on the structure of the `CELO_CORE_CONTRACTS` environment
  variable, see `app/explorer/lib/fetch_celo_core_contracts.ex`.
  """
  @dialyzer :no_match

  require Logger

  alias EthereumJSONRPC
  alias Explorer.Chain.Block

  @type contract_name :: String.t()

  @atom_to_contract_name %{
    accounts: "Accounts",
    celo_token: "GoldToken",
    election: "Election",
    epoch_rewards: "EpochRewards",
    locked_gold: "LockedGold",
    reserve: "Reserve",
    usd_token: "StableToken",
    validators: "Validators",
    governance: "Governance",
    fee_handler: "FeeHandler"
  }

  @atom_to_contract_event_names %{
    fee_handler: %{
      fee_beneficiary_set: "FeeBeneficiarySet",
      burn_fraction_set: "BurnFractionSet"
    },
    epoch_rewards: %{
      carbon_offsetting_fund_set: "CarbonOffsettingFundSet"
    }
  }

  @doc """
  A map where keys are atoms representing contract types, and values are strings
  representing the names of the contracts.
  """
  @spec atom_to_contract_name() :: %{atom() => contract_name}
  def atom_to_contract_name, do: @atom_to_contract_name

  @doc """
  A nested map where keys are atoms representing contract types, and values are
  maps of event atoms to event names.
  """
  @spec atom_to_contract_event_names() :: %{atom() => %{atom() => contract_name}}
  def atom_to_contract_event_names, do: @atom_to_contract_event_names

  @doc """
  Gets the specified event for a core contract at a given block number.

  ## Parameters
  - `contract_atom`: The atom representing the contract.
  - `event_atom`: The atom representing the event.
  - `block_number`: The block number at which to fetch the event.

  ## Returns (one of the following)
  - `{:ok, map() | nil}`: The event data if found, or `nil` if no event is found.
  - `{:error, reason}`: An error tuple with the reason for the failure.
  """
  @spec get_event(atom(), atom(), Block.block_number()) ::
          {:ok, map() | nil}
          | {:error,
             :contract_atom_not_found
             | :event_atom_not_found
             | :contract_name_not_found
             | :event_name_not_found
             | :contract_address_not_found}
  def get_event(contract_atom, event_atom, block_number) do
    core_contracts = Application.get_env(:explorer, __MODULE__)[:contracts]

    with {:ok, address} when not is_nil(address) <- get_address(contract_atom, block_number),
         {:contract_atom, {:ok, contract_name}} <-
           {:contract_atom, Map.fetch(@atom_to_contract_name, contract_atom)},
         {:event_atom, {:ok, event_name}} <-
           {
             :event_atom,
             @atom_to_contract_event_names
             |> Map.get(contract_atom, %{})
             |> Map.fetch(event_atom)
           },
         {:events, {:ok, contract_name_to_addresses}} <-
           {:events, Map.fetch(core_contracts, "events")},
         {:contract_name, {:ok, contract_addresses}} <-
           {:contract_name, Map.fetch(contract_name_to_addresses, contract_name)},
         {:contract_address, {:ok, contract_events}} <-
           {:contract_address, Map.fetch(contract_addresses, address)},
         {:event_name, {:ok, event_updates}} <-
           {:event_name, Map.fetch(contract_events, event_name)} do
      current_event =
        event_updates
        |> Enum.take_while(&(&1["updated_at_block_number"] <= block_number))
        |> Enum.take(-1)
        |> List.first()

      {:ok, current_event}
    else
      nil ->
        {:ok, nil}

      {:contract_atom, :error} ->
        Logger.error("Unknown contract atom: #{inspect(contract_atom)}")
        {:error, :contract_atom_not_found}

      {:event_atom, :error} ->
        Logger.error("Unknown event atom: #{inspect(event_atom)}")
        {:error, :event_atom_not_found}

      {:events, :error} ->
        raise "Missing `events` key in CELO core contracts JSON"

      {:contract_name, :error} ->
        Logger.error(fn ->
          [
            "Unknown name for contract atom: #{contract_atom}, ",
            "ensure `CELO_CORE_CONTRACTS` env var is set ",
            "and the provided JSON contains required key"
          ]
        end)

        {:error, :contract_name_not_found}

      {:event_name, :error} ->
        Logger.error(fn ->
          [
            "Unknown name for event atom: #{event_atom}, ",
            "ensure `CELO_CORE_CONTRACTS` env var is set ",
            "and the provided JSON contains required key"
          ]
        end)

        {:error, :event_name_not_found}

      {:contract_address, :error} ->
        Logger.error(fn ->
          [
            "Unknown address for contract atom: #{contract_atom}, ",
            "ensure `CELO_CORE_CONTRACTS` env var is set ",
            "and the provided JSON contains required key"
          ]
        end)

        {:error, :contract_address_not_found}

      error ->
        error
    end
  end

  @doc """
  Gets the address of a core contract at a given block number.

  ## Parameters
  - `contract_atom`: The atom representing the contract.
  - `block_number`: The block number at which to fetch the address.

  ## Returns (one of the following)
  - `{:ok, EthereumJSONRPC.address() | nil}`: The address of the contract, or `nil` if not found.
  - `{:error, reason}`: An error tuple with the reason for the failure.
  """
  @spec get_address(atom(), Block.block_number()) ::
          {:ok, EthereumJSONRPC.address() | nil}
          | {:error,
             :contract_atom_not_found
             | :contract_name_not_found}
  def get_address(
        contract_atom,
        block_number
      ) do
    core_contracts = Application.get_env(:explorer, __MODULE__)[:contracts]

    with {:atom, {:ok, contract_name}} <-
           {:atom, Map.fetch(@atom_to_contract_name, contract_atom)},
         {:addresses, {:ok, contract_name_to_addresses}} <-
           {:addresses, Map.fetch(core_contracts, "addresses")},
         {:name, {:ok, address_updates}} <-
           {:name, Map.fetch(contract_name_to_addresses, contract_name)} do
      current_address =
        address_updates
        |> Enum.take_while(&(&1["updated_at_block_number"] <= block_number))
        |> Enum.take(-1)
        |> case do
          [%{"address" => address}] ->
            address

          _ ->
            nil
        end

      {:ok, current_address}
    else
      {:atom, :error} ->
        Logger.error("Unknown contract atom: #{inspect(contract_atom)}")
        {:error, :contract_atom_not_found}

      {:addresses, :error} ->
        raise "Missing `addresses` key in CELO core contracts JSON"

      {:name, :error} ->
        Logger.error(fn ->
          [
            "Unknown name for contract atom: #{contract_atom}, ",
            "ensure `CELO_CORE_CONTRACTS` env var is set ",
            "and the provided JSON contains required key"
          ]
        end)

        {:error, :contract_name_not_found}
    end
  end
end
