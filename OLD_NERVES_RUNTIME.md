## Loading WiFi kernel module (unnecessary for newer versions of `nerves_runtime`)

**Note**
If you are using `nerves_runtime` >= `0.3.0` the kernel module will be auto
loaded by default, and this step is not necessary.

Before WiFi will work, you will need to load any modules for your device if they
aren't loaded already. Here's an example for Raspberry Pi 0 and Raspberry Pi 3:

``` elixir
defmodule MyApplication do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Task, [fn -> init_kernel_modules() end], restart: :transient, id: Nerves.Init.KernelModules)
    ]

    opts = [strategy: :one_for_one, name: MyApplication.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def init_kernel_modules() do
    {_, 0} = System.cmd("modprobe", ["brcmfmac"])
  end
end

```

