package org.openmrs.module.chuschedules;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;
import org.openmrs.Privilege;
import org.openmrs.api.UserService;
import org.openmrs.api.context.Context;
import org.openmrs.module.BaseModuleActivator;

/**
 * Stopping this module stops generation and nothing else. Blocks it has already created are
 * ordinary appointment blocks and stay valid, bookable and editable in the existing UI, so there is
 * never anything to migrate back.
 */
public class ChuSchedulesActivator extends BaseModuleActivator {
	
	private static final Log log = LogFactory.getLog(ChuSchedulesActivator.class);
	
	@Override
	public void started() {
		ensurePrivilegeExists();
		log.info("Started CHU Recurring Schedules");
	}
	
	@Override
	public void stopped() {
		log.info("Stopped CHU Recurring Schedules; generated blocks are unaffected");
	}
	
	/**
	 * Created here rather than in liquibase so that it is restored if someone deletes it, and so
	 * the description explains what granting it actually means.
	 */
	private void ensurePrivilegeExists() {
		UserService userService = Context.getUserService();
		Privilege existing = userService.getPrivilege(ChuSchedulesConstants.PRIVILEGE_MANAGE);
		if (existing != null) {
			return;
		}
		Context.addProxyPrivilege("Manage Privileges");
		try {
			Privilege privilege = new Privilege(ChuSchedulesConstants.PRIVILEGE_MANAGE,
			        "Create and generate recurring provider schedules. Grants the ability to set "
			                + "months of clinic availability in a single action.");
			userService.savePrivilege(privilege);
			log.info("Created privilege: " + ChuSchedulesConstants.PRIVILEGE_MANAGE);
		}
		catch (Exception e) {
			// Never prevent the module, or the application, from starting over a privilege.
			log.error("Could not create the " + ChuSchedulesConstants.PRIVILEGE_MANAGE + " privilege", e);
		}
		finally {
			Context.removeProxyPrivilege("Manage Privileges");
		}
	}
}
