import { LightningElement, api } from 'lwc';

const DEBOUNCE_MS = 250;
const MIN_TERM = 2;

/**
 * The zoomed view of a single tile: full prompt at a readable size, and the
 * "who did you meet?" interaction that a 5x5 cell on a phone cannot host.
 *
 * Still presentational. It owns the debounce and reports intent — `search`,
 * `mark`, `unmark`, `close` — while the container owns every Apex call. That
 * keeps it mockable in tests and reusable on a read-only board.
 */
export default class BingoTileDetail extends LightningElement {
    @api square;
    @api busy = false;
    @api searching = false;

    _results = [];
    @api
    get searchResults() {
        return this._results;
    }
    set searchResults(value) {
        this._results = value ?? [];
    }

    term = '';
    selectedId;
    selectedName = '';
    validationMessage = '';
    _timer;

    disconnectedCallback() {
        clearTimeout(this._timer);
    }

    // ------------------------------------------------------------ Derived

    get isMarked() {
        return !!this.square?.isMarked;
    }

    get hasSelection() {
        return !!this.selectedId;
    }

    get showResults() {
        return !this.selectedId && this._results.length > 0;
    }

    get showNoMatch() {
        return (
            !this.selectedId &&
            !this.searching &&
            this.term.trim().length >= MIN_TERM &&
            this._results.length === 0
        );
    }

    get submitDisabled() {
        return this.busy || !this.selectedId;
    }

    get submitLabel() {
        if (this.busy) {
            return 'Saving…';
        }
        return this.isMarked ? 'Update' : 'Mark it';
    }

    // ------------------------------------------------------------ Search

    handleInput(event) {
        this.term = event.target.value;
        this.selectedId = undefined;
        this.validationMessage = '';

        clearTimeout(this._timer);
        const term = this.term.trim();
        if (term.length < MIN_TERM) {
            this.dispatchEvent(new CustomEvent('search', { detail: { term: '' } }));
            return;
        }
        // Debounced: a keystroke-per-query would hammer Apex over conference wifi.
        this._timer = setTimeout(() => {
            this.dispatchEvent(new CustomEvent('search', { detail: { term } }));
        }, DEBOUNCE_MS);
    }

    handlePick(event) {
        this.selectedId = event.currentTarget.dataset.id;
        this.selectedName = event.currentTarget.dataset.name;
        this.term = this.selectedName;
        this.dispatchEvent(new CustomEvent('search', { detail: { term: '' } }));
    }

    handleClear() {
        this.selectedId = undefined;
        this.selectedName = '';
        this.term = '';
        this.dispatchEvent(new CustomEvent('search', { detail: { term: '' } }));
    }

    // ------------------------------------------------------------ Actions

    handleSubmit() {
        if (!this.selectedId) {
            this.validationMessage = 'Pick the person from the list — they need to be registered.';
            return;
        }
        this.dispatchEvent(
            new CustomEvent('mark', {
                detail: {
                    rowIndex: this.square.rowIndex,
                    colIndex: this.square.colIndex,
                    metPlayerId: this.selectedId
                }
            })
        );
    }

    handleUnmark() {
        this.dispatchEvent(
            new CustomEvent('unmark', {
                detail: {
                    rowIndex: this.square.rowIndex,
                    colIndex: this.square.colIndex
                }
            })
        );
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}
