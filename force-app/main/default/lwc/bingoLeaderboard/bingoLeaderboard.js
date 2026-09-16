import { LightningElement, api } from 'lwc';
import getLeaderboard from '@salesforce/apex/BingoService.getLeaderboard';

/**
 * Standalone leaderboard. Its own container rather than a view inside bingoCard,
 * so it can sit on its own page or a booth screen without dragging the game in.
 *
 * Scores are derived from the marks log on every call, so there is nothing to
 * recalculate or keep in sync — a refresh is always authoritative.
 */
export default class BingoLeaderboard extends LightningElement {
    @api backUrl = '';
    @api maxRows = 25;
    @api refreshSeconds = 0;   // >0 turns it into a self-refreshing booth display

    rows = [];
    loading = true;
    errorMessage = '';
    _timer;

    connectedCallback() {
        this.load();
        const every = Number(this.refreshSeconds);
        if (every > 0) {
            this._timer = setInterval(() => this.load(), every * 1000);
        }
    }

    disconnectedCallback() {
        clearInterval(this._timer);
    }

    get showBackLink() {
        return !!this.backUrl;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get isEmpty() {
        return !this.loading && this.rows.length === 0;
    }

    async load() {
        try {
            const data = await getLeaderboard({ maxRows: Number(this.maxRows) || 25 });
            this.rows = data.map((row) => ({
                ...row,
                rowClass: row.rank <= 3 ? 'row row--podium' : 'row',
                detail: this.detailFor(row)
            }));
            this.errorMessage = '';
        } catch (error) {
            this.errorMessage = error?.body?.message || 'Could not load the leaderboard.';
        } finally {
            this.loading = false;
        }
    }

    detailFor(row) {
        const parts = [`${row.squares} square${row.squares === 1 ? '' : 's'}`];
        if (row.lines) {
            parts.push(`${row.lines} line${row.lines === 1 ? '' : 's'}`);
        }
        if (row.helped) {
            parts.push(`met by ${row.helped}`);
        }
        if (row.blackout) {
            parts.push('BLACKOUT');
        }
        return parts.join(' · ');
    }

    handleRefresh() {
        this.loading = true;
        this.load();
    }
}
