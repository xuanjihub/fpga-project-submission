package com.xuanjihub.fpgainstrument.ui

import com.xuanjihub.fpgainstrument.ble.AdsrField
import com.xuanjihub.fpgainstrument.ble.BridgeSnapshot

/**
 * Applies one bridge snapshot to the UI state.
 *
 * Every parameter's draft is reconciled independently: a snapshot updates a
 * draft when that parameter's own version changed. A MASTER CAS leaves an
 * unconfirmed timbre or ADSR draft untouched.
 */
internal fun AppUiState.applyBridgeSnapshot(snapshot: BridgeSnapshot): AppUiState {
    if (!ready) return this
    // A failed refresh clears the snapshot (state/timbre/ADSR = null) while the
    // bridge identity came from the link. Keep it so the UI can still say
    // "BLE + INFO verified, FPGA not verified" and offer a retry.
    val info = snapshot.info ?: this.info
    val supportsTimbre = info?.profile?.supportsTimbre == true
    val supportsAdsr = info?.profile?.supportsAdsr == true
    val boardTimbre = if (supportsTimbre) snapshot.timbre else null
    val stateChanged = snapshot.state != null && snapshot.stateVersion != stateVersion
    val timbreChanged = boardTimbre != null && snapshot.timbreVersion != timbreVersion
    val boardAdsr = if (supportsAdsr) snapshot.adsr else emptyMap()
    var nextDrafts = adsrDrafts
    for (field in AdsrField.entries) {
        val state = boardAdsr[field] ?: continue
        if (snapshot.adsrVersions[field] != adsrVersions[field]) {
            nextDrafts = nextDrafts + (field to state.index)
        }
    }
    return copy(
        info = info,
        state = snapshot.state,
        readFailure = if (snapshot.state != null) null else readFailure,
        stateReadAtMillis = snapshot.stateReadAtMillis,
        stateVersion = snapshot.stateVersion,
        masterDraft = if (stateChanged) snapshot.state.master else masterDraft,
        timbre = boardTimbre,
        timbreReadAtMillis = if (supportsTimbre) snapshot.timbreReadAtMillis else null,
        timbreVersion = snapshot.timbreVersion,
        timbreDraft = if (timbreChanged) boardTimbre.timbre else timbreDraft,
        adsr = boardAdsr,
        adsrReadAtMillis = if (supportsAdsr) snapshot.adsrReadAtMillis else emptyMap(),
        adsrVersions = snapshot.adsrVersions,
        adsrDrafts = nextDrafts,
    )
}
