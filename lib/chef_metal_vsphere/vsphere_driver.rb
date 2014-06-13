require 'chef'
require 'chef_metal/driver'
require 'cheffish/merged_config'
require 'chef_metal/machine/windows_machine'
require 'chef_metal/machine/unix_machine'
require 'chef_metal_vsphere/version'
require 'chef_metal_vsphere/vsphere_helpers'
require 'chef_metal_vsphere/vsphere_url'

module ChefMetalVsphere
  # Provisions machines in vSphere.
  class VsphereDriver < ChefMetal::Driver
    include Chef::Mixin::ShellOut
    include ChefMetalVsphere::Helpers

    def self.from_url(driver_url, config)
      VsphereDriver.new(driver_url, config)
    end

    def self.canonicalize_url(driver_url, config)
      config = symbolize_keys(config)
      new_defaults = {
       :driver_options => { :connect_options => { :port     => 443,
                                                  :use_ssl      => true,
                                                  :insecure => false,
                                                  :path     => '/sdk'
        } },
                       :machine_options => { :start_timeout => 600, 
                                             :create_timeout => 600, 
                                             :bootstrap_options => { :ssh => { :port => 22,
                                                                               :user => 'root' }} }
      }

      new_connect_options = {}
      new_connect_options[:provider] = 'vsphere'
      if driver_url
        uri = URI(driver_url)
        new_connect_options[:host] = uri.host
        new_connect_options[:port] = uri.port
        if uri.path.length > 0
          new_connect_options[:path] = uri.path
        end
        new_connect_options[:use_ssl] = uri.use_ssl
        new_connect_options[:insecure] = uri.insecure
      end
      new_connect_options = new_connect_options.merge(config[:driver_options])

      new_config = { :driver_options => { :connect_options => new_connect_options }}
      config = Cheffish::MergedConfig.new(new_config, config, new_defaults)

      required_options = [:host, :user, :password]
      missing_options = []
      required_options.each do |opt|
        missing_options << opt unless config[:driver_options][:connect_options].has_key?(opt)
      end
      unless missing_options.empty?
        raise "missing required options: #{missing_options.join(', ')}"
      end

      url = URI::VsphereUrl.from_config(config[:driver_options][:connect_options]).to_s
      [ url, config ]
    end

    def self.symbolize_keys(h)
      Hash === h ?
        Hash[
          h.map do |k, v|
            [k.respond_to?(:to_sym) ? k.to_sym : k, symbolize_keys(v)]
          end
        ] : h
    end

    # Create a new Vsphere provisioner.
    #
    # ## Parameters
    # connect_options - hash of options to be passed to RbVmomi::VIM.connect
    #   :host       - required - hostname of the vSphere API server
    #   :port       - optional - port on the vSphere API server (default: 443)
    #   :path        - optional - path on the vSphere API server (default: /sdk)
    #   :use_ssl        - optional - true to use ssl in connection to vSphere API server (default: true)
    #   :insecure   - optional - true to ignore ssl certificate validation errors in connection to vSphere API server (default: false)
    #   :user       - required - user name to use in connection to vSphere API server
    #   :password   - required - password to use in connection to vSphere API server
    #   :proxy_host         - optional - http proxy host to use in connection to vSphere API server (default: none)
    #   :proxy_port         - optional - http proxy port to use in connection to vSphere API server (default: none)
    def initialize(driver_url, config)
      super(driver_url, config)
      @connect_options = config[:driver_options][:connect_options].to_hash

      # test vim connection
      vim || raise("cannot connect to [#{provisioner_url}]")
    end

    attr_reader :connect_options

    # Acquire a machine, generally by provisioning it.  Returns a Machine
    # object pointing at the machine, allowing useful actions like setup,
    # converge, execute, file and directory.  The Machine object will have a
    # "node" property which must be saved to the server (if it is any
    # different from the original node object).
    #
    # ## Parameters
    # action_handler - the action_handler object that is calling this method; this
    #        is generally a action_handler, but could be anything that can support the
    #        ChefMetal::ActionHandler interface (i.e., in the case of the test
    #        kitchen metal driver for acquiring and destroying VMs; see the base
    #        class for what needs providing).
    # node - node object (deserialized json) representing this machine.  If
    #        the node has a provisioner_options hash in it, these will be used
    #        instead of options provided by the provisioner.  TODO compare and
    #        fail if different?
    #        node will have node['normal']['provisioner_options'] in it with any options.
    #        It is a hash with this format:
    #
    #           -- provisioner_url: vsphere://host:port?ssl=[true|false]&insecure=[true|false]
    #           -- bootstrap_options: hash of options to pass to RbVmomi::VIM::VirtualMachine::CloneTask()
    #                :datacenter
    #                :resource_pool
    #                :cluster
    #                :datastore
    #                :template_name
    #                :template_folder
    #                :vm_folder
    #                :winrm {...} (not yet implemented)
    #                :ssh {...}
    #
    #        Example bootstrap_options for vSphere:
    #          TODO: add other CloneTask params, e.g.: datastore, annotation, resource_pool, ...
    #          'bootstrap_options' => {
    #            'template_name' =>'centos6.small',
    #            'template_folder' =>'Templates',
    #            'vm_folder' => 'MyApp'
    #          }
    #
    #        node['normal']['provisioner_output'] will be populated with information
    #        about the created machine.  For vSphere, it is a hash with this
    #        format:
    #
    #           -- provisioner_url: vsphere:host:port?ssl=[true|false]&insecure=[true|false]
    #           -- vm_folder: name of the vSphere folder containing the VM
    #
    def allocate_machine(action_handler, machine_spec, machine_options)
      if machine_spec.location
        vm = vm_for(machine_spec)
        if vm
          return vm
        else
          Chef::Log.warn "Machine #{machine_spec.name} (#{machine_spec.location['server_id']} on #{driver_url}) no longer exists.  Recreating ..."
        end
      end
      bootstrap_options = bootstrap_options_for(machine_spec, machine_options)
      vm = nil

      if bootstrap_options[:ssh]
        wait_on_port = bootstrap_options[:ssh][:port]
        raise "Must specify bootstrap_options[:ssh][:port]" if wait_on_port.nil?
      else
        raise 'bootstrapping is currently supported for ssh only'
        # wait_on_port = bootstrap_options['winrm']['port']
      end

      description = [ "creating machine #{machine_spec.name} on #{driver_url}" ]
      bootstrap_options.each_pair { |key,value| description << "  #{key}: #{value.inspect}" }
      action_handler.report_progress description

      # TODO compare new options to existing and fail if we cannot change it
      # over (perhaps introduce a boolean that will force a delete and recreate
      # in such a case)
      
      vm = clone_vm(bootstrap_options)

      machine_spec.location = {
        'driver_url' => driver_url,
        'driver_version' => VERSION,
        'server_id' => vm.config.instanceUuid,
        'is_windows' => is_windows?(vm),
        'allocated_at' => Time.now.utc.to_s
      }
      machine_spec.location['key_name'] = bootstrap_options[:key_name] if bootstrap_options[:key_name]
      %w(ssh_username sudo use_private_ip_for_ssh ssh_gateway).each do |key|
        machine_spec.location[key] = machine_options[key.to_sym] if machine_options[key.to_sym]
      end

      action_handler.performed_action "machine #{machine_spec.name} created as #{machine_spec.location['server_id']} on #{driver_url}"
      vm
    end

    def ready_machine(action_handler, machine_spec, machine_options)
      start_machine(action_handler, machine_spec, machine_options)
      vm = vm_for(machine_spec)
      if vm.nil?
        raise "Machine #{machine_spec.name} does not have a server associated with it, or server does not exist."
      end

      wait_until_ready(action_handler, machine_spec, machine_options, vm)

      begin
        wait_for_transport(action_handler, machine_spec, machine_options, vm)
      rescue Timeout::Error
        # Only ever reboot once, and only if it's been less than 10 minutes since we stopped waiting
        if machine_spec.location['started_at'] || remaining_wait_time(machine_spec, machine_options) < -(10*60)
          raise
        else
          Chef::Log.warn "Machine #{machine_spec.name} (#{server.config.instanceUuid} on #{driver_url}) was started but SSH did not come up.  Rebooting machine in an attempt to unstick it ..."
          restart_server(action_handler, machine_spec, vm)
          wait_until_ready(action_handler, machine_spec, machine_options, vm)
          wait_for_transport(action_handler, machine_spec, machine_options, vm)
        end
      end

      machine = machine_for(machine_spec, machine_options, vm)

      machine
    end

    # Connect to machine without acquiring it
    def connect_to_machine(machine_spec, machine_options)
      machine_for(machine_spec, machine_options)
    end

    def destroy_machine(action_handler, machine_spec, machine_options)
      vm = vm_for(machine_spec)
      if vm
        action_handler.perform_action "Delete VM [#{vm.parent.name}/#{vm.name}]" do
          vm.PowerOffVM_Task.wait_for_completion unless vm.runtime.powerState == 'poweredOff'
          vm.Destroy_Task.wait_for_completion
          machine_spec.location = nil
        end
      end
      strategy = convergence_strategy_for(machine_spec, machine_options)
      begin
        strategy.cleanup_convergence(action_handler, machine_spec)
      rescue URI::InvalidURIError
        raise unless Chef::Config.local_mode
      end
    end

    def stop_machine(action_handler, machine_spec, machine_options)
      vm = vm_for(machine_spec)
      if vm
        action_handler.perform_action "Shutdown guest OS and power off VM [#{vm.parent.name}/#{vm.name}]" do
          stop_vm(vm)
        end
      end
    end

    def start_machine(action_handler, machine_spec, machine_options)
      vm = vm_for(machine_spec)
      if vm
        action_handler.perform_action "Power on VM [#{vm.parent.name}/#{vm.name}]" do
          bootstrap_options = bootstrap_options_for(machine_spec, machine_options)
          start_vm(vm, bootstrap_options[:ssh][:port])
        end
      end
    end

    def restart_server(action_handler, machine_spec, vm)
      action_handler.perform_action "restart machine #{machine_spec.name} (#{vm.config.instanceUuid} on #{driver_url})" do
        stop_machine(action_handler, machine_spec, vm)
        start_vm(vm)
        machine_spec.location['started_at'] = Time.now.utc.to_s
      end
    end

    protected

    def remaining_wait_time(machine_spec, machine_options)
      if machine_spec.location['started_at']
        machine_options[:start_timeout] - (Time.now.utc - Time.parse(machine_spec.location['started_at']))
      else
        machine_options[:create_timeout] - (Time.now.utc - Time.parse(machine_spec.location['allocated_at']))
      end
    end

    def wait_until_ready(action_handler, machine_spec, machine_options, vm)
      if vm.guest.toolsRunningStatus != "guestToolsRunning"
        perform_action = true
        if action_handler.should_perform_actions
          action_handler.report_progress "waiting for #{machine_spec.name} (#{vm.config.instanceUuid} on #{driver_url}) to be ready ..."
          until remaining_wait_time(machine_spec, machine_options) < 0 || (vm.guest.toolsRunningStatus == "guestToolsRunning" && vm.guest.ipAddress.length > 0) do
            print "."
            sleep 5
          end
          action_handler.report_progress "#{machine_spec.name} is now ready"
        end
      end
    end

    def vm_for(machine_spec)
      if machine_spec.location
        find_vm_by_id(machine_spec.location['server_id'])
      else
        nil
      end
    end

    def bootstrap_options_for(machine_spec, machine_options)
      bootstrap_options = machine_options[:bootstrap_options] || {}
      if !bootstrap_options[:key_name]
        bootstrap_options[:key_name] = 'metal_default'
      end
      tags = {
          'Name' => machine_spec.name,
          'BootstrapId' => machine_spec.id,
          'BootstrapHost' => Socket.gethostname,
          'BootstrapUser' => Etc.getlogin
      }
      # User-defined tags override the ones we set
      tags.merge!(bootstrap_options[:tags]) if bootstrap_options[:tags]
      bootstrap_options.merge!({ :tags => tags })
      bootstrap_options[:name] ||= machine_spec.name
      bootstrap_options
    end

    def clone_vm(bootstrap_options)
      vm_name         = bootstrap_options[:name]
      datacenter      = bootstrap_options[:datacenter]
      template_folder = bootstrap_options[:template_folder]
      template_name   = bootstrap_options[:template_name]

      vm = find_vm(datacenter, bootstrap_options[:vm_folder], vm_name)
      return vm if vm

      vm_template = find_vm(datacenter, template_folder, template_name) or raise("vSphere VM Template not found [#{template_folder}/#{template_name}]")

      do_vm_clone(datacenter, vm_template, vm_name, bootstrap_options)
    end

    def machine_for(machine_spec, machine_options, vm = nil)
      vm ||= vm_for(machine_spec)
      if !vm
        raise "Server for node #{machine_spec.name} has not been created!"
      end

      if machine_spec.location['is_windows']
        ChefMetal::Machine::WindowsMachine.new(machine_spec, transport_for(machine_spec, machine_options, vm), convergence_strategy_for(machine_spec, machine_options))
      else
        ChefMetal::Machine::UnixMachine.new(machine_spec, transport_for(machine_spec, machine_options, vm), convergence_strategy_for(machine_spec, machine_options))
      end
    end

    def is_windows?(vm)
      return false if vm.nil?
      vm.guest.guestFamily == 'windowsGuest'
    end

    def convergence_strategy_for(machine_spec, machine_options)
      require 'chef_metal/convergence_strategy/install_msi'
      require 'chef_metal/convergence_strategy/install_cached'
      require 'chef_metal/convergence_strategy/no_converge'
      # Defaults
      if !machine_spec.location
        return ChefMetal::ConvergenceStrategy::NoConverge.new(machine_options[:convergence_options], config)
      end

      if machine_spec.location['is_windows']
        ChefMetal::ConvergenceStrategy::InstallMsi.new(machine_options[:convergence_options], config)
      else
        ChefMetal::ConvergenceStrategy::InstallCached.new(machine_options[:convergence_options], config)
      end
    end

    def wait_for_transport(action_handler, machine_spec, machine_options, vm)
      transport = transport_for(machine_spec, machine_options, vm)
      if !transport.available?
        if action_handler.should_perform_actions
          action_handler.report_progress "waiting for #{machine_spec.name} (#{vm.instance.Uuid} on #{driver_url}) to be connectable (transport up and running) ..."

          _self = self

          until remaining_wait_time(machine_spec, machine_options) || transport.available? do
            print "."
            sleep 5
          end

          action_handler.report_progress "#{machine_spec.name} is now connectable"
        end
      end
    end

    def transport_for(machine_spec, machine_options, vm)
      if is_windows?(vm)
        create_winrm_transport(machine_spec, machine_options, vm)
      else
        create_ssh_transport(machine_spec, machine_options, vm)
      end
    end

    def create_winrm_transport(machine_spec, machine_options, vm)
      raise 'Windows guest VMs are not yet supported'
    end

    def create_ssh_transport(machine_spec, machine_options, vm)
      require 'chef_metal/transport/ssh'
      bootstrap_options = bootstrap_options_for(machine_spec, machine_options)
      ssh_options = bootstrap_options[:ssh]
      ssh_user = ssh_options[:user]
      remote_host = vm.guest.ipAddress

      ChefMetal::Transport::SSH.new(remote_host, ssh_user, ssh_options, {}, config)
    end
  end
end