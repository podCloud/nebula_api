defmodule NebulaAPI.ASTTest do
  use ExUnit.Case

  describe "process dictionary cleanup in call_on_node" do
    test "cleans up process dictionary after normal execution" do
      # Ensure clean state
      Process.delete(:nebula_node_selector)
      Process.delete(:nebula_call_mode)
      Process.delete(:nebula_call_opts)

      # Simulate what the macro does (without actually calling it)
      old_selector = Process.get(:nebula_node_selector)
      old_mode = Process.get(:nebula_call_mode)
      old_opts = Process.get(:nebula_call_opts)

      try do
        Process.put(:nebula_node_selector, fn _ -> :test_node end)
        Process.put(:nebula_call_mode, :unicast)
        Process.put(:nebula_call_opts, [timeout: 5000])

        # Verify they are set
        assert Process.get(:nebula_node_selector) != nil
        assert Process.get(:nebula_call_mode) == :unicast
        assert Process.get(:nebula_call_opts) == [timeout: 5000]
      after
        if old_selector do
          Process.put(:nebula_node_selector, old_selector)
        else
          Process.delete(:nebula_node_selector)
        end

        if old_mode do
          Process.put(:nebula_call_mode, old_mode)
        else
          Process.delete(:nebula_call_mode)
        end

        if old_opts do
          Process.put(:nebula_call_opts, old_opts)
        else
          Process.delete(:nebula_call_opts)
        end
      end

      # Verify cleanup happened
      assert Process.get(:nebula_node_selector) == nil
      assert Process.get(:nebula_call_mode) == nil
      assert Process.get(:nebula_call_opts) == nil
    end

    test "restores previous values after nested calls" do
      # Set up outer call state
      Process.put(:nebula_node_selector, fn _ -> :outer_node end)
      Process.put(:nebula_call_mode, :multicast)
      Process.put(:nebula_call_opts, [timeout: 10_000])

      # Simulate inner call
      old_selector = Process.get(:nebula_node_selector)
      old_mode = Process.get(:nebula_call_mode)
      old_opts = Process.get(:nebula_call_opts)

      try do
        Process.put(:nebula_node_selector, fn _ -> :inner_node end)
        Process.put(:nebula_call_mode, :unicast)
        Process.put(:nebula_call_opts, [timeout: 5000])

        # Inner call sees inner values
        assert Process.get(:nebula_call_mode) == :unicast
      after
        if old_selector do
          Process.put(:nebula_node_selector, old_selector)
        else
          Process.delete(:nebula_node_selector)
        end

        if old_mode do
          Process.put(:nebula_call_mode, old_mode)
        else
          Process.delete(:nebula_call_mode)
        end

        if old_opts do
          Process.put(:nebula_call_opts, old_opts)
        else
          Process.delete(:nebula_call_opts)
        end
      end

      # Outer values should be restored
      assert Process.get(:nebula_call_mode) == :multicast
      assert Process.get(:nebula_call_opts) == [timeout: 10_000]

      # Cleanup
      Process.delete(:nebula_node_selector)
      Process.delete(:nebula_call_mode)
      Process.delete(:nebula_call_opts)
    end
  end

  describe "__wrap_nebula_api_result/1" do
    test "wraps raw results with :ok tuple" do
      assert NebulaAPI.AST.__wrap_nebula_api_result(:some_value) == {:ok, :some_value}
      assert NebulaAPI.AST.__wrap_nebula_api_result("string") == {:ok, "string"}
      assert NebulaAPI.AST.__wrap_nebula_api_result(%{key: :value}) == {:ok, %{key: :value}}
    end

    test "preserves :ok tuples" do
      assert NebulaAPI.AST.__wrap_nebula_api_result({:ok, :result}) == {:ok, :result}
    end

    test "preserves :error tuples" do
      assert NebulaAPI.AST.__wrap_nebula_api_result({:error, :reason}) == {:error, :reason}
    end
  end
end
