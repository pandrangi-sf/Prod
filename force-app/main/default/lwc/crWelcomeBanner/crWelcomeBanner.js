import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import USER_ID from '@salesforce/user/Id';
import FIRST_NAME from '@salesforce/schema/User.FirstName';

// Stored in localStorage so it persists across page navigations within the day.
// Value is a YYYY-MM-DD string in the user's local timezone.
const SHOWN_DATE_STORAGE_KEY = 'crWelcomeBanner.lastShownDate';

/**
 * Greets the running user with a time-of-day message + tool name and a
 * friendly cloud mascot. Shows once per local-day on the first page in the
 * framework that loads after midnight; subsequent pages on the same day no-op.
 *
 * Drop the banner at the top of any user-facing component:
 *   <c-cr-welcome-banner tool-name="Vital Reports"></c-cr-welcome-banner>
 *
 * Falls back gracefully:
 *   - No FirstName access -> "there"
 *   - No localStorage (private mode / blocked) -> shows every page load
 *     (rare, and the dismiss button still works)
 */
export default class CrWelcomeBanner extends LightningElement {
    @api toolName = 'Vital Reports';

    @track visible = false;
    @track userFirstName = '';

    @wire(getRecord, { recordId: USER_ID, fields: [FIRST_NAME] })
    wiredUser({ data }) {
        if (data) {
            this.userFirstName = getFieldValue(data, FIRST_NAME) || '';
        }
    }

    connectedCallback() {
        if (this.shouldShowToday()) {
            this.markShownToday();
            this.visible = true;
        }
    }

    shouldShowToday() {
        try {
            const stored = window.localStorage.getItem(SHOWN_DATE_STORAGE_KEY);
            return stored !== this.todayKey();
        } catch (e) {
            // Private browsing / blocked storage — default to showing.
            return true;
        }
    }

    markShownToday() {
        try {
            window.localStorage.setItem(SHOWN_DATE_STORAGE_KEY, this.todayKey());
        } catch (e) {
            // Storage blocked — banner will re-appear on next page, accepted tradeoff.
        }
    }

    todayKey() {
        const now = new Date();
        const year = now.getFullYear();
        const month = String(now.getMonth() + 1).padStart(2, '0');
        const day = String(now.getDate()).padStart(2, '0');
        return `${year}-${month}-${day}`;
    }

    get greeting() {
        const hour = new Date().getHours();
        if (hour >= 5 && hour < 12) return 'Good morning';
        if (hour >= 12 && hour < 17) return 'Good afternoon';
        if (hour >= 17 && hour < 24) return 'Good evening';
        return 'Hello';
    }

    get displayName() {
        return this.userFirstName ? this.userFirstName : 'there';
    }

    get headlineText() {
        return `${this.greeting}, ${this.displayName}!`;
    }

    get subText() {
        return `Welcome to ${this.toolName || 'Vital Reports'}.`;
    }

    handleDismiss() {
        this.visible = false;
    }
}