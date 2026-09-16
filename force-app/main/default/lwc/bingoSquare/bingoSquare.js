import { LightningElement, api } from 'lwc';

const TRUNCATE_AT = 58;

/**
 * One tile in the 5x5 grid. Deliberately presentational: it holds no state,
 * makes no Apex calls, and only reports that it was tapped. That keeps it
 * reusable for a read-only board (leaderboard, staff preview) with no changes.
 */
export default class BingoSquare extends LightningElement {
    @api square;
    @api readOnly = false;

    get cssClass() {
        const classes = ['tile'];
        if (this.square?.isFreeSpace) {
            classes.push('tile--free');
        } else if (this.square?.isMarked) {
            classes.push('tile--marked');
        }
        if (this.square?.pending) {
            classes.push('tile--pending');
        }
        return classes.join(' ');
    }

    /** The grid is a glance view — the full text lives in the zoomed tile. */
    get shortText() {
        const text = this.square?.promptText ?? '';
        return text.length > TRUNCATE_AT ? `${text.slice(0, TRUNCATE_AT - 1)}…` : text;
    }

    get ariaLabel() {
        if (this.square?.isFreeSpace) {
            return 'Free space, already marked';
        }
        const state = this.square?.isMarked
            ? `marked, met ${this.square.metPersonName || 'someone'}`
            : 'not yet marked';
        return `${this.square?.promptText ?? ''} — ${state}`;
    }

    get showCheck() {
        return this.square?.isMarked && !this.square?.isFreeSpace;
    }

    handleClick() {
        if (this.readOnly) {
            return;
        }
        this.dispatchEvent(
            new CustomEvent('squareselect', {
                detail: {
                    rowIndex: this.square.rowIndex,
                    colIndex: this.square.colIndex
                }
            })
        );
    }
}
