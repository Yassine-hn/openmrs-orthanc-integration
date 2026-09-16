package org.openmrs.module.chuschedules.generator;

/**
 * Why a candidate day produced no block. Every skip is reported with one of these, so a generation
 * run can be audited after the fact rather than guessed at.
 */
public enum SkipReason {
	
	/** The date is today or earlier. The past is a record, not a schedule. */
	PAST,
	
	/** The template is switched off. */
	TEMPLATE_INACTIVE,
	
	/** The date falls outside the template's validity period. */
	OUTSIDE_VALIDITY,
	
	/** A holiday or leave day excluded the date. The detail carries the reason text. */
	EXCEPTION,
	
	/** This range already produced a block for this date. Re-running changes nothing. */
	ALREADY_GENERATED,
	
	/**
	 * An appointment block already covers this time. Existing blocks always win; we never shadow or
	 * duplicate work someone entered by hand.
	 */
	OVERLAPS_EXISTING
}
