import { LightningElement, api, track } from 'lwc';
import startSession from '@salesforce/apex/BingoService.startSession';
import markSquare from '@salesforce/apex/BingoService.markSquare';
import unmarkSquare from '@salesforce/apex/BingoService.unmarkSquare';
import searchPlayers from '@salesforce/apex/BingoService.searchPlayers';

const STORAGE_KEY = 'df26-bingo-email';

const VIEW = {
    ENTRY: 'entry',
    GRID: 'grid',
    TILE: 'tile'
};

/**
 * Container for Networking Bingo. Owns all state and every Apex call; the two
 * child components stay presentational.
 *
 * Two views by design: the 5x5 grid is a glance surface, and tapping a tile
 * zooms into bingoTileDetail where the prompt is readable and the interaction
 * has room. A 5x5 grid on a phone is far too small to read or type into.
 */
export default class BingoCard extends LightningElement {
    /**
     * Set in Experience Builder once the leaderboard page exists. Left blank the
     * link simply does not render, so a missing page can never produce a dead link.
     */
    @api leaderboardUrl = '';

    @track card;
    email = '';
    displayName = '';

    view = VIEW.ENTRY;
    selected;
    loading = false;
    busy = false;
    errorMessage = '';

    searchResults = [];
    searching = false;

    // ------------------------------------------------------------ Lifecycle

    connectedCallback() {
        // Returning on the same device skips re-typing the email. The card itself
        // is derived server-side from that email, so this is only a convenience.
        const saved = this.safeGetStoredEmail();
        if (saved) {
            this.email = saved;
            this.resume();
        }
    }

    // ------------------------------------------------------------ Derived state

    get showEntry() {
        return this.view === VIEW.ENTRY;
    }
    get showGrid() {
        return this.view === VIEW.GRID;
    }
    get showTile() {
        return this.view === VIEW.TILE;
    }

    get startDisabled() {
        // Only an email is required. Storing it is how the game works, not an
        // optional extra, so it is explained in a notice rather than gated behind
        // a checkbox nobody can decline — a forced tick isn't consent.
        return this.loading || !this.email.trim();
    }

    get startLabel() {
        return this.loading ? 'Getting your card…' : 'Get my card';
    }

    /** Squares carry a stable key so LWC does not reuse DOM across re-renders. */
    get squares() {
        return (this.card?.squares ?? []).map((square) => ({
            ...square,
            key: `${square.rowIndex}-${square.colIndex}`
        }));
    }

    get progressLabel() {
        if (!this.card) {
            return '';
        }
        return `${this.card.markedCount} of ${this.card.totalCount} squares`;
    }

    get progressStyle() {
        if (!this.card?.totalCount) {
            return 'width: 0%';
        }
        const pct = Math.round((this.card.markedCount / this.card.totalCount) * 100);
        return `width: ${pct}%`;
    }

    get greeting() {
        return this.card?.displayName ? `Nice one, ${this.card.displayName}` : 'Your card';
    }

    get score() {
        return this.card?.score;
    }

    get scoreLabel() {
        const s = this.card?.score;
        if (!s) {
            return '';
        }
        const parts = [`${s.squares} square${s.squares === 1 ? '' : 's'}`];
        if (s.lines) {
            parts.push(`${s.lines} line${s.lines === 1 ? '' : 's'}`);
        }
        if (s.helped) {
            parts.push(`met by ${s.helped}`);
        }
        return parts.join(' · ');
    }

    get showLeaderboardLink() {
        return !!this.leaderboardUrl;
    }

    get switchLabel() {
        return this.card?.displayName ? `Not ${this.card.displayName}?` : 'Switch player';
    }

    get hasWon() {
        return !!this.card?.bingoAchieved;
    }

    get hasBlackout() {
        return !!this.card?.blackout;
    }

    get winMessage() {
        return this.hasBlackout
            ? 'BLACKOUT! Every square. Show this screen at the booth.'
            : 'BINGO! Show this screen at the booth.';
    }

    // ------------------------------------------------------------ Entry

    handleEmailInput(event) {
        this.email = event.target.value;
    }

    handleNameInput(event) {
        this.displayName = event.target.value;
    }

    async handleStart() {
        if (this.startDisabled) {
            return;
        }
        this.loading = true;
        this.errorMessage = '';
        try {
            this.card = await startSession({
                email: this.email,
                displayName: this.displayName,
                consented: true      // acknowledged by proceeding past the notice
            });
            this.safeStoreEmail(this.card.email);
            this.view = VIEW.GRID;
        } catch (error) {
            this.errorMessage = this.readError(error);
        } finally {
            this.loading = false;
        }
    }

    /** Restore on reload without re-asking for consent already given. */
    async resume() {
        this.loading = true;
        try {
            this.card = await startSession({
                email: this.email,
                displayName: null,
                consented: true
            });
            this.view = VIEW.GRID;
        } catch (error) {
            // A stale or now-invalid email should not trap the player on a dead screen.
            this.safeClearStoredEmail();
            this.view = VIEW.ENTRY;
        } finally {
            this.loading = false;
        }
    }

    /**
     * Escape hatch. The stored email makes returning frictionless, but it also
     * means a shared or borrowed phone is stuck as the previous player — and in
     * Chrome every incognito window shares one session, so there is otherwise no
     * way back to the entry form.
     */
    handleSwitch() {
        this.safeClearStoredEmail();
        this.card = undefined;
        this.selected = undefined;
        this.searchResults = [];
        this.email = '';
        this.displayName = '';
        this.errorMessage = '';
        this.view = VIEW.ENTRY;
    }

    // ------------------------------------------------------------ Grid <-> tile

    handleSquareSelect(event) {
        const { rowIndex, colIndex } = event.detail;
        this.selected = this.squares.find(
            (square) => square.rowIndex === rowIndex && square.colIndex === colIndex
        );
        this.view = VIEW.TILE;
    }

    handleClose() {
        this.selected = undefined;
        this.searchResults = [];
        this.view = VIEW.GRID;
    }

    /**
     * The child debounces and asks; the container does the calling. An empty term
     * is a clear, not a query.
     */
    async handleSearch(event) {
        const term = event.detail.term;
        if (!term) {
            this.searchResults = [];
            this.searching = false;
            return;
        }
        this.searching = true;
        try {
            this.searchResults = await searchPlayers({ term, excludeEmail: this.card?.email });
        } catch (error) {
            this.searchResults = [];
        } finally {
            this.searching = false;
        }
    }

    // ------------------------------------------------------------ Marking

    async handleMark(event) {
        const { rowIndex, colIndex, metPlayerId } = event.detail;
        const picked = this.searchResults.find((p) => p.playerId === metPlayerId);
        await this.applyChange(
            () => markSquare({ email: this.card.email, rowIndex, colIndex, metPlayerId }),
            {
                rowIndex,
                colIndex,
                isMarked: true,
                metPersonName: picked ? picked.displayName : null
            }
        );
    }

    async handleUnmark(event) {
        const { rowIndex, colIndex } = event.detail;
        await this.applyChange(
            () => unmarkSquare({ email: this.card.email, rowIndex, colIndex }),
            { rowIndex, colIndex, isMarked: false, metPersonName: null }
        );
    }

    /**
     * Optimistic update: paint the change immediately, then reconcile with the
     * server's authoritative card. Conference wifi is slow enough that waiting on
     * the round-trip makes every tap feel broken; on failure we roll back.
     *
     * The board is replaced wholesale rather than mutated in place — LWC does not
     * re-render on nested mutation, so the child's @api setter would never fire.
     */
    async applyChange(request, optimistic) {
        const snapshot = this.card;
        this.card = this.withLocalChange(snapshot, optimistic);
        this.syncSelected();
        this.busy = true;
        this.errorMessage = '';

        try {
            this.card = await request();
            this.syncSelected();
            this.view = VIEW.GRID;
            this.selected = undefined;
        } catch (error) {
            this.card = snapshot;
            this.syncSelected();
            this.errorMessage = this.readError(error);
        } finally {
            this.busy = false;
            this.searchResults = [];
        }
    }

    withLocalChange(card, { rowIndex, colIndex, isMarked, metPersonName }) {
        const squares = card.squares.map((square) =>
            square.rowIndex === rowIndex && square.colIndex === colIndex
                ? { ...square, isMarked, metPersonName, pending: true }
                : square
        );
        const markedCount = squares.filter((s) => s.isMarked && !s.isFreeSpace).length;
        return { ...card, squares, markedCount };
    }

    syncSelected() {
        if (!this.selected) {
            return;
        }
        this.selected = this.squares.find(
            (square) =>
                square.rowIndex === this.selected.rowIndex &&
                square.colIndex === this.selected.colIndex
        );
    }

    // ------------------------------------------------------------ Helpers

    readError(error) {
        return (
            error?.body?.message ||
            error?.message ||
            'Something went wrong. Check your connection and try again.'
        );
    }

    // localStorage throws in private mode on some browsers; never let that break play.
    safeGetStoredEmail() {
        try {
            return window.localStorage.getItem(STORAGE_KEY);
        } catch (e) {
            return null;
        }
    }

    safeStoreEmail(value) {
        try {
            window.localStorage.setItem(STORAGE_KEY, value);
        } catch (e) {
            // non-fatal
        }
    }

    safeClearStoredEmail() {
        try {
            window.localStorage.removeItem(STORAGE_KEY);
        } catch (e) {
            // non-fatal
        }
    }
}
