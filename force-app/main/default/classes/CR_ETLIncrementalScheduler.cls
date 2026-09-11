/**
 * Schedulable wrapper for the incremental fact refresh. Scheduled every ~30 min
 * (see CR_ETLScheduler.scheduleIncremental) so newly created/edited source records
 * surface in Fact-based reports within minutes rather than at the next nightly run.
 * Delegates to CR_ETLScheduler.runIncrementalFacts, which fans out each fact batch
 * with a recent sinceDate watermark (add/update only — no stale-row deletion).
 */
public with sharing class CR_ETLIncrementalScheduler implements Schedulable {
    public void execute(SchedulableContext context) {
        CR_ETLScheduler.runIncrementalFacts();
    }
}