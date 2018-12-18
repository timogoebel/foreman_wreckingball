# frozen_string_literal: true

module ForemanWreckingball
  module HypervisorsHelper
    def wreckingball_spectre_v2_status(vmware_hypervisor_facet)
      if vmware_hypervisor_facet.feature_capabilities.blank?
        icon_text('unknown', '', kind: 'pficon', title: _('N/A'))
      elsif vmware_hypervisor_facet.provides_spectre_features?
        icon_text('ok', '', kind: 'pficon', title: _('CPU-Features are present on this host.'))
      else
        icon_text('error-circle-o', '', kind: 'pficon', title: _('Required CPU features are missing. This host is most likely vulnerable.'))
      end
    end

    def wreckingball_rhel_subscription_status(host)
      if host.subscription_facet && host.subscription_facet.hypervisor && host.subscriptions.count > 0 && host.subscriptions.map(&:redhat?).all?
        icon_text('ok', '', kind: 'pficon', title: _('This host has a valid RHEL subscription.'))
      else
        icon_text('error-circle-o', '', kind: 'pficon', title: _('This host is not subscribed correctly as a hypervisor.'))
      end
    end
  end
end
