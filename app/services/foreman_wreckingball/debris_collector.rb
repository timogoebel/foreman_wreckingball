require 'rbvmomi'

module ForemanWreckingball
  class DebrisCollector

    PROPERTY_MAPPING = {
      :VirtualMachine => {
        mapped: {
          cpus: 'config.hardware.numCPU',
          corespersocket: 'config.hardware.numCoresPerSocket',
          memory_mb: 'config.hardware.memoryMB',
          tools_state: 'guest.toolsStatus',
          guest_id: 'config.guestId',
          cpu_hot_add: 'config.cpuHotAddEnabled',
          hardware_version: 'config.version',
          #cpu_features: ''
        },
        additional: [
          'name',
          'config.instanceUuid'
        ]
      },
      :Folder => {
        mapped: {
          name: 'name'
        },
        additional: [
          'childEntity'
        ]
      },
    }.freeze

    attr_reader :compute_resource
    attr_accessor :version, :stop_requested

    delegate :logger, to: ::Rails

    def initialize(compute_resource:)
      logger.debug "Wreckingball Debris Collector: Initializing."
      @compute_resource = compute_resource
      self.version = ''
      self.stop_requested = false
    end


    def run
      logger.debug "Wreckingball Debris Collector: Started."

      property_filter

      logger.debug "Wreckingball Debris Collector: Starting initial import."
      initial_refresh
      logger.debug "Wreckingball Debris Collector: Finished initial import."

      logger.debug "Wreckingball Debris Collector: Finished."
    ensure
      destroy_property_filter
    end

    def stop
      logger.debug "Wreckingball Debris Collector: Stop requested."
      self.stop_requested = true
    end

    private

    def initial_refresh
      monitor_updates
    end

    def monitor_updates
      begin
        update_set = wait_for_updates
        return version if update_set.nil?

        self.version = update_set.version
        process_update_set(update_set)
      end while update_set.truncated
    end

    def process_update_set(update_set)
      property_filter_update = update_set.filterSet.to_a.detect do |update|
        update.filter == property_filter
      end
      return if property_filter_update.nil?

      object_update_set = property_filter_update.objectSet
      return if object_update_set.blank?

      logger.debug "Wreckingball Debris Collector: Processing #{object_update_set.count} updates..."

      process_object_update_set(object_update_set)

      logger.debug "Wreckingball Debris Collector: Processing #{object_update_set.count} updates... completed."
    end

    def process_object_update_set(object_update_set)
      object_update_set.each do |object_update|
        process_object_update(object_update)
      end
    end

    def process_object_update(object_update)
      managed_object = object_update.obj

      logger.debug "#{object_update.kind} #{object_update.obj.class.wsdl_name}:#{object_update.obj._ref}"

      case object_update.obj.class.wsdl_name
      when 'VirtualMachine'
        process_virtual_machine_update(object_update)
      else
        # Ignore this for now
      end
    end

    def process_virtual_machine_update(object_update)
      managed_object = object_update.obj
      # TODO: Cache this
      uuid = managed_object.config.instanceUuid

      logger.error "Processing for uuid #{uuid}"

      host = Host::Managed.find_by(compute_resource: compute_resource, uuid: uuid)

      return unless host

      facet = host.vmware_facet || host.build_vmware_facet

      # TODO: Cluster
      facet.update(
        map_update_to_properties(:VirtualMachine, object_update.changeSet)
      )
    end

    def map_update_to_properties(type, change_set)
      mapping = PROPERTY_MAPPING[type][:mapped]

      change_set.each_with_object({}) do |property_change, hsh|
        hsh[mapping.key(property_change.name)] = property_change.val if mapping.key(property_change.name)
      end
    end

    def wait_for_updates
      connection.propertyCollector.WaitForUpdatesEx(
        :version => version,
        :options => wait_for_updates_options
      )
    end

    def wait_for_updates_options
      RbVmomi::VIM.WaitOptions(
        :maxWaitSeconds => 10
      )
    end

    def property_filter
      @property_filter ||= create_property_filter
    end

    def property_set
      PROPERTY_MAPPING.map do |type, properties|
        RbVmomi::VIM::PropertySpec(
          type: type,
          pathSet: properties[:mapped].values + (properties[:additional] || [])
        )
      end
    end

    def traversal_spec_folder_to_child_entity
      RbVmomi::VIM.TraversalSpec(
        :name => 'FolderTraversalSpec',
        :type => 'Folder',
        :path => 'childEntity',
        :skip => false,
        :selectSet => [
          RbVmomi::VIM.SelectionSpec(:name => 'FolderTraversalSpec'),
          #RbVmomi::VIM.SelectionSpec(:name => 'tsDcToDsFolder'),
          #RbVmomi::VIM.SelectionSpec(:name => 'tsDcToHostFolder'),
          #RbVmomi::VIM.SelectionSpec(:name => 'tsDcToNetworkFolder'),
          RbVmomi::VIM.SelectionSpec(:name => 'DatacenterToVmFolderTraversalSpec'),
          #RbVmomi::VIM.SelectionSpec(:name => 'tsCrToHost'),
          #RbVmomi::VIM.SelectionSpec(:name => 'tsCrToRp'),
          #RbVmomi::VIM.SelectionSpec(:name => 'tsRpToRp'),
          #RbVmomi::VIM.SelectionSpec(:name => 'tsRpToVm')
        ]
      )
    end

    def traversal_spec_datacenter_to_vm_folder
      RbVmomi::VIM.TraversalSpec(
        :name => 'DatacenterToVmFolderTraversalSpec',
        :type => 'Datacenter',
        :path => 'vmFolder',
        :skip => false,
        :selectSet => [
          RbVmomi::VIM.SelectionSpec(:name => 'FolderTraversalSpec')
        ]
      )
    end

    def object_set(root)
      traversal_spec = [
        traversal_spec_folder_to_child_entity,
        #datacenter_to_datastore_folder,
        #datacenter_to_host_folder,
        #datacenter_to_network_folder,
        traversal_spec_datacenter_to_vm_folder
        #compute_resource_to_host,
        #compute_resource_to_resource_pool,
        #resource_pool_to_resource_pool,
        #resource_pool_to_vm,
      ]

      RbVmomi::VIM.ObjectSpec(
        :obj => root,
        :selectSet => traversal_spec
      )
    end

    def create_property_filter
      property_filter_spec = RbVmomi::VIM.PropertyFilterSpec(
        :objectSet => [
          object_set(
            root_folder
          )
        ],
        :propSet => property_set
      )

      connection.propertyCollector.CreateFilter(
        :spec => property_filter_spec,
        :partialUpdates => true
      )
    end

    def destroy_property_filter
      return unless @property_filter
      @property_filter.DestroyPropertyFilter
    end

    def root_folder
      connection.serviceContent.rootFolder
    end

    def connection
      compute_resource.send(:client).send(:connection)
    end
  end
end
