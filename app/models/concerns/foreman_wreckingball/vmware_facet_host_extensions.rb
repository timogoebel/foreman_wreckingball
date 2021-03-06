module ForemanWreckingball
  module VmwareFacetHostExtensions
    extend ActiveSupport::Concern

    included do
      has_one :vmware_facet, :class_name => '::ForemanWreckingball::VmwareFacet', :foreign_key => :host_id, :inverse_of => :host, :dependent => :destroy

      before_provision :queue_vmware_facet_refresh
    end

    def refresh_vmware_facet!
      facet = self.vmware_facet || self.build_vmware_facet
      facet.refresh!
      facet.persisted? && facet.refresh_statuses
    end

    def queue_vmware_facet_refresh
      ForemanTasks.delay(
        ::Actions::ForemanWreckingball::Host::RefreshVmwareFacet,
        { :start_at => Time.now + 5.minutes },
        self
      ) if managed? && compute? && provider == 'VMware'
      true
    end
  end
end
