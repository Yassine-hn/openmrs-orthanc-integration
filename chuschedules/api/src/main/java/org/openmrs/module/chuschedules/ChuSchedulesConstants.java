package org.openmrs.module.chuschedules;

/**
 * A template sets months of hospital-wide availability in one action, so it gets its own privilege
 * rather than riding on the existing appointment-scheduling ones.
 */
public final class ChuSchedulesConstants {
	
	public static final String PRIVILEGE_MANAGE = "Manage Recurring Schedules";
	
	public static final String MODULE_ID = "chuschedules";
	
	private ChuSchedulesConstants() {
	}
}
