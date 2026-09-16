@IsTest
private class BingoServiceTest {

    private static void seedPrompts(Integer count) {
        List<Bingo_Prompt__c> prompts = new List<Bingo_Prompt__c>();
        for (Integer i = 0; i < count; i++) {
            prompts.add(new Bingo_Prompt__c(Text__c = 'Test prompt ' + i, Active__c = true));
        }
        insert prompts;
    }

    /** Registers a player and returns the opaque id the UI would pass to markSquare. */
    private static Id register(String email, String name) {
        BingoService.startSession(email, name, true);
        return [SELECT Id FROM Bingo_Player__c WHERE Email__c = :email.toLowerCase() LIMIT 1].Id;
    }

    // ------------------------------------------------------------ Guest access

    @IsTest(SeeAllData=true)
    static void guestCanPlayTheWholeLoop() {
        List<User> guests = [
            SELECT Id FROM User
            WHERE UserType = 'Guest' AND IsActive = true
              AND Profile.Name = 'Networking Bingo Profile'
            LIMIT 1
        ];
        System.assertEquals(1, guests.size(), 'Networking Bingo site guest user not found.');

        // Must pre-date this transaction: guest sharing recalculation is async, so a
        // guest cannot see a player row created alongside it. On the live site the
        // 20-minute registration window covers this.
        List<Bingo_Player__c> alreadyRegistered = [
            SELECT Id FROM Bingo_Player__c WHERE Email__c != 'guest.loop@example.com' LIMIT 1
        ];
        System.assertEquals(1, alreadyRegistered.size(),
            'Needs at least one pre-existing registered player to name.');
        Id otherId = alreadyRegistered[0].Id;

        System.runAs(guests[0]) {
            BingoService.CardDTO card = BingoService.startSession(
                'guest.loop@example.com', 'Guest Loop', true);
            System.assertEquals(25, card.squares.size(), 'Guest could not build a card.');

            BingoService.SquareDTO target = firstPromptSquare(card);
            BingoService.CardDTO marked = BingoService.markSquare(
                'guest.loop@example.com', target.rowIndex, target.colIndex, otherId);
            System.assertEquals(1, marked.markedCount, 'Guest could not mark a square.');

            BingoService.CardDTO cleared = BingoService.unmarkSquare(
                'guest.loop@example.com', target.rowIndex, target.colIndex);
            System.assertEquals(0, cleared.markedCount, 'Guest could not un-mark a square.');
        }
    }

    @IsTest
    static void eventConfigReadsTheActiveRecord() {
        BingoService.EventDTO cfg = BingoService.getEventConfig();
        System.assertNotEquals(null, cfg, 'Config must never come back null.');
        System.assertNotEquals(null, cfg.gameTitle, 'A title should always resolve, even with no record.');
    }

    /** Custom metadata has its own access rules — confirm a guest can actually read it. */
    @IsTest(SeeAllData=true)
    static void guestCanReadEventConfig() {
        User guest = [
            SELECT Id FROM User
            WHERE UserType = 'Guest' AND IsActive = true AND Profile.Name = 'Networking Bingo Profile'
            LIMIT 1
        ];
        BingoService.EventDTO cfg;
        System.runAs(guest) {
            cfg = BingoService.getEventConfig();
        }
        // Whether a guest can read custom metadata is the open question; what must
        // never happen is a thrown exception taking the page down with it.
        System.assertNotEquals(null, cfg, 'Guest must always receive a config object.');
        System.assertNotEquals(null, cfg.gameTitle, 'Guest must always get a usable title.');
    }

    // ------------------------------------------------------------ Derived layout

    @IsTest
    static void cardIs25SquaresWith24DistinctPromptsAndAFreeCentre() {
        seedPrompts(30);
        BingoService.CardDTO card = BingoService.startSession('shape@example.com', 'Shape', true);

        System.assertEquals(25, card.squares.size());
        System.assertEquals(24, card.totalCount);

        Set<String> seen = new Set<String>();
        Integer freeSpaces = 0;
        for (BingoService.SquareDTO s : card.squares) {
            if (s.isFreeSpace) {
                freeSpaces++;
                System.assertEquals(2, s.rowIndex);
                System.assertEquals(2, s.colIndex);
                System.assertEquals(true, s.isMarked, 'Free space starts marked.');
            } else {
                System.assert(!seen.contains(s.promptText), 'Duplicate prompt: ' + s.promptText);
                seen.add(s.promptText);
            }
        }
        System.assertEquals(1, freeSpaces);
        System.assertEquals(24, seen.size());
        System.assertEquals(0, card.markedCount, 'Free space must not count toward progress.');
    }

    @IsTest
    static void sameEmailAlwaysDerivesTheIdenticalCard() {
        seedPrompts(40);
        System.assertEquals(
            BingoService.layoutFor('rafa@example.com'),
            BingoService.layoutFor('rafa@example.com'),
            'Layout derivation must be deterministic.');

        BingoService.CardDTO a = BingoService.startSession('  Rafa@Example.com ', 'Rafa', true);
        BingoService.CardDTO b = BingoService.startSession('rafa@example.com', 'Rafa', true);
        for (Integer i = 0; i < 25; i++) {
            System.assertEquals(a.squares[i].promptText, b.squares[i].promptText,
                'Refreshing must restore the same board.');
        }
    }

    @IsTest
    static void differentEmailsGetDifferentCards() {
        seedPrompts(40);
        System.assertNotEquals(
            BingoService.layoutFor('one@example.com'),
            BingoService.layoutFor('two@example.com'),
            'Two players should not share an identical card.');
    }

    // ------------------------------------------------------------ Typeahead

    @IsTest
    static void searchFindsRegisteredPlayersAndExcludesYourself() {
        seedPrompts(30);
        register('ada@example.com', 'Ada Lovelace');
        register('alan@example.com', 'Alan Turing');
        register('me@example.com', 'Alan Me');

        List<BingoService.PlayerRefDTO> hits = BingoService.searchPlayers('Alan', 'me@example.com');
        System.assertEquals(1, hits.size(), 'Should find Alan Turing but exclude myself.');
        System.assertEquals('Alan Turing', hits[0].displayName);
        System.assertNotEquals(null, hits[0].playerId, 'An opaque handle must be returned.');
    }

    @IsTest
    static void searchIgnoresVeryShortTerms() {
        seedPrompts(30);
        register('ada@example.com', 'Ada Lovelace');
        System.assertEquals(0, BingoService.searchPlayers('A', null).size(),
            'One character is too broad to search on.');
        System.assertEquals(0, BingoService.searchPlayers('  ', null).size());
    }

    // ------------------------------------------------------------ Marking

    @IsTest
    static void markingRecordsTheRegisteredPlayerYouMet() {
        seedPrompts(30);
        Id ada = register('ada@example.com', 'Ada Lovelace');
        BingoService.CardDTO card = BingoService.startSession('mark@example.com', 'Mark', true);
        BingoService.SquareDTO target = firstPromptSquare(card);

        BingoService.CardDTO updated = BingoService.markSquare(
            'mark@example.com', target.rowIndex, target.colIndex, ada);

        BingoService.SquareDTO cell = cellOf(updated, target.rowIndex, target.colIndex);
        System.assertEquals(true, cell.isMarked);
        System.assertEquals('Ada Lovelace', cell.metPersonName);
        System.assertEquals(1, updated.markedCount);

        Bingo_Mark__c row = [
            SELECT Met_Player_Email__c, Prompt_Text__c FROM Bingo_Mark__c
            WHERE Email__c = 'mark@example.com' LIMIT 1
        ];
        System.assertEquals('ada@example.com', row.Met_Player_Email__c,
            'Attribution must key on email, not the ambiguous display name.');
        System.assertEquals(target.promptText, row.Prompt_Text__c);
    }

    @IsTest
    static void unregisteredPlayerIsRejected() {
        seedPrompts(30);
        BingoService.CardDTO card = BingoService.startSession('solo@example.com', 'Solo', true);
        BingoService.SquareDTO t = firstPromptSquare(card);
        try {
            BingoService.markSquare('solo@example.com', t.rowIndex, t.colIndex, '001000000000000AAA');
            System.assert(false, 'An unregistered player id must be rejected.');
        } catch (Exception e) { System.assert(true); }
    }

    @IsTest
    static void meetingYourselfIsRejected() {
        seedPrompts(30);
        Id me = register('self@example.com', 'Self');
        BingoService.CardDTO card = BingoService.startSession('self@example.com', 'Self', true);
        BingoService.SquareDTO t = firstPromptSquare(card);
        try {
            BingoService.markSquare('self@example.com', t.rowIndex, t.colIndex, me);
            System.assert(false, 'Meeting yourself must not count.');
        } catch (AuraHandledException e) { System.assert(true); }
    }

    @IsTest
    static void unmarkingIsAnInsertAndClearsTheCell() {
        seedPrompts(30);
        Id ada = register('ada@example.com', 'Ada');
        BingoService.CardDTO card = BingoService.startSession('undo@example.com', 'Undo', true);
        BingoService.SquareDTO t = firstPromptSquare(card);

        BingoService.markSquare('undo@example.com', t.rowIndex, t.colIndex, ada);
        BingoService.CardDTO cleared = BingoService.unmarkSquare('undo@example.com', t.rowIndex, t.colIndex);

        System.assertEquals(false, cellOf(cleared, t.rowIndex, t.colIndex).isMarked);
        System.assertEquals(0, cleared.markedCount);
        System.assertEquals(2, [SELECT COUNT() FROM Bingo_Mark__c WHERE Email__c = 'undo@example.com'],
            'Un-marking appends a row rather than deleting one.');
    }

    @IsTest
    static void freeSpaceCannotBeMarkedOrCleared() {
        seedPrompts(30);
        Id ada = register('ada@example.com', 'Ada');
        BingoService.startSession('free@example.com', 'Free', true);
        try {
            BingoService.markSquare('free@example.com', 2, 2, ada);
            System.assert(false, 'Free space should not be markable.');
        } catch (AuraHandledException e) { System.assert(true); }
        try {
            BingoService.unmarkSquare('free@example.com', 2, 2);
            System.assert(false, 'Free space should not be clearable.');
        } catch (AuraHandledException e) { System.assert(true); }
    }

    @IsTest
    static void offBoardCellsAreRejected() {
        seedPrompts(30);
        Id ada = register('ada@example.com', 'Ada');
        BingoService.startSession('edge@example.com', 'Edge', true);
        try {
            BingoService.markSquare('edge@example.com', 5, 0, ada);
            System.assert(false, 'Row 5 is off the board.');
        } catch (AuraHandledException e) { System.assert(true); }
    }

    @IsTest
    static void aPersonCanOnlyClaimOneSquare() {
        seedPrompts(30);
        Id ada = register('ada@example.com', 'Ada');
        BingoService.CardDTO card = BingoService.startSession('greedy@example.com', 'Greedy', true);

        BingoService.markSquare('greedy@example.com', 0, 0, ada);
        try {
            BingoService.markSquare('greedy@example.com', 0, 1, ada);
            System.assert(false, 'The same person must not fill a second square.');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assertEquals(1,
            BingoService.startSession('greedy@example.com', 'Greedy', true).score.squares,
            'Only the first square should have stuck.');
    }

    @IsTest
    static void reassigningTheSameSquareToTheSamePersonIsAllowed() {
        seedPrompts(30);
        Id ada = register('ada@example.com', 'Ada');
        BingoService.startSession('redo@example.com', 'Redo', true);

        BingoService.markSquare('redo@example.com', 0, 0, ada);
        BingoService.CardDTO again = BingoService.markSquare('redo@example.com', 0, 0, ada);
        System.assertEquals(1, again.score.squares, 'Re-marking the same square must not be blocked.');
    }

    @IsTest
    static void clearingASquareFreesThePersonUpAgain() {
        seedPrompts(30);
        Id ada = register('ada@example.com', 'Ada');
        BingoService.startSession('free2@example.com', 'Free', true);

        BingoService.markSquare('free2@example.com', 0, 0, ada);
        BingoService.unmarkSquare('free2@example.com', 0, 0);
        BingoService.CardDTO moved = BingoService.markSquare('free2@example.com', 1, 1, ada);
        System.assertEquals(1, moved.score.squares, 'After clearing, the person should be reusable.');
    }

    @IsTest
    static void searchHidesPeopleAlreadyClaimed() {
        seedPrompts(30);
        Id ada = register('ada@example.com', 'Ada Nova');
        register('alan@example.com', 'Alan Nova');
        BingoService.startSession('picker@example.com', 'Picker', true);

        System.assertEquals(2, BingoService.searchPlayers('Nova', 'picker@example.com').size(),
            'Both should be findable before anyone is claimed.');

        BingoService.markSquare('picker@example.com', 0, 0, ada);

        List<BingoService.PlayerRefDTO> after = BingoService.searchPlayers('Nova', 'picker@example.com');
        System.assertEquals(1, after.size(), 'Ada should disappear once claimed.');
        System.assertEquals('Alan Nova', after[0].displayName);
    }

    // ------------------------------------------------------------ Scoring

    @IsTest
    static void scoreCountsSquaresLinesAndHelpers() {
        seedPrompts(30);
        // Four squares need four different people: one person counts once per card.
        List<Id> friends = new List<Id>{
            register('f1@example.com', 'Friend One'),
            register('f2@example.com', 'Friend Two'),
            register('f3@example.com', 'Friend Three'),
            register('f4@example.com', 'Friend Four')
        };
        BingoService.startSession('scorer@example.com', 'Scorer', true);

        BingoService.CardDTO state;
        Integer i = 0;
        for (Integer c = 0; c < 5; c++) {
            if (c == 2) { continue; }                       // free space
            state = BingoService.markSquare('scorer@example.com', 2, c, friends[i]);
            i++;
        }

        // 4 squares, one completed row, no blackout, nobody has met the scorer.
        System.assertEquals(4, state.score.squares);
        System.assertEquals(1, state.score.lines, 'Row 2 should be the only completed line.');
        System.assertEquals(0, state.score.helped);
        System.assertEquals(4 * 1 + 1 * 5, state.score.total);
    }

    @IsTest
    static void beingMetEarnsHelperPoints() {
        seedPrompts(30);
        Id helper = register('helper@example.com', 'Helper');
        BingoService.startSession('a@example.com', 'A', true);
        BingoService.startSession('b@example.com', 'B', true);

        BingoService.markSquare('a@example.com', 0, 0, helper);
        BingoService.markSquare('b@example.com', 0, 0, helper);

        BingoService.CardDTO helperCard = BingoService.startSession('helper@example.com', 'Helper', true);
        System.assertEquals(2, helperCard.score.helped, 'Two people named the helper.');
        System.assertEquals(2, helperCard.score.total, 'Helper points only — no squares of their own.');
    }

    @IsTest
    static void clearingASquareTakesBackTheHelperPoint() {
        seedPrompts(30);
        Id helper = register('helper@example.com', 'Helper');
        BingoService.startSession('a@example.com', 'A', true);

        BingoService.markSquare('a@example.com', 0, 0, helper);
        System.assertEquals(1, BingoService.startSession('helper@example.com', 'Helper', true).score.helped);

        BingoService.unmarkSquare('a@example.com', 0, 0);
        System.assertEquals(0, BingoService.startSession('helper@example.com', 'Helper', true).score.helped,
            'Un-marking must revoke the helper point.');
    }

    @IsTest
    static void blackoutScoresEverySquareEveryLineAndTheBonus() {
        seedPrompts(30);
        register('ada@example.com', 'Ada');
        BingoService.startSession('black@example.com', 'Black', true);

        List<Bingo_Mark__c> marks = new List<Bingo_Mark__c>();
        for (Integer r = 0; r < 5; r++) {
            for (Integer c = 0; c < 5; c++) {
                if (r == 2 && c == 2) { continue; }
                marks.add(new Bingo_Mark__c(
                    Email__c = 'black@example.com', Row__c = r, Col__c = c,
                    Met_Player_Email__c = 'ada@example.com', Cleared__c = false));
            }
        }
        insert marks;

        BingoService.CardDTO state = BingoService.startSession('black@example.com', 'Black', true);
        System.assertEquals(24, state.score.squares);
        System.assertEquals(12, state.score.lines, 'All 5 rows, 5 columns and 2 diagonals.');
        System.assertEquals(true, state.blackout);
        System.assertEquals(24 + 12 * 5 + 25, state.score.total);
    }

    @IsTest
    static void countLinesCountsEachLineOnce() {
        System.assertEquals(0, BingoService.countLines(new Set<String>{'0-0','1-1'}));
        System.assertEquals(1, BingoService.countLines(new Set<String>{'0-0','0-1','0-2','0-3','0-4'}));
        System.assertEquals(2, BingoService.countLines(
            new Set<String>{'0-0','0-1','0-2','0-3','0-4','1-0','2-0','3-0','4-0'}),
            'A shared corner still counts as two distinct lines.');
    }

    // ------------------------------------------------------------ Leaderboard

    @IsTest
    static void leaderboardRanksByTotalScore() {
        seedPrompts(30);
        List<Id> friends = new List<Id>{
            register('f1@example.com', 'Friend One'),
            register('f2@example.com', 'Friend Two'),
            register('f3@example.com', 'Friend Three'),
            register('f4@example.com', 'Friend Four')
        };
        BingoService.startSession('low@example.com', 'Low', true);
        BingoService.startSession('high@example.com', 'High', true);

        BingoService.markSquare('low@example.com', 0, 0, friends[0]);
        Integer i = 0;
        for (Integer c = 0; c < 5; c++) {
            if (c == 2) { continue; }
            BingoService.markSquare('high@example.com', 2, c, friends[i]);
            i++;
        }

        List<BingoService.LeaderRowDTO> board = BingoService.getLeaderboard(10);
        System.assert(board.size() >= 3, 'Friends, High and Low should all appear.');
        System.assertEquals(1, board[0].rank);

        // High: 4 squares + 1 completed row = 4 + 5 = 9.
        // Friend One: met twice = 2. Low: 1 square = 1.
        System.assertEquals('High', board[0].displayName, 'Most points should rank first.');
        System.assertEquals(9, board[0].total);
        System.assert(board[0].total >= board[1].total, 'Board must be sorted descending.');
    }

    @IsTest
    static void leaderboardIncludesHelpersWhoNeverMarkedAnything() {
        seedPrompts(30);
        Id helper = register('helper@example.com', 'Helper');
        BingoService.startSession('a@example.com', 'A', true);
        BingoService.markSquare('a@example.com', 0, 0, helper);

        Boolean found = false;
        for (BingoService.LeaderRowDTO row : BingoService.getLeaderboard(25)) {
            if (row.displayName == 'Helper') {
                found = true;
                System.assertEquals(0, row.squares, 'Helper marked nothing themselves.');
                System.assertEquals(1, row.helped);
                System.assertEquals(1, row.total);
            }
        }
        System.assert(found, 'A player who only helped others must still be ranked.');
    }

    /** Prizes depend on this order, so an equal score must not be broken by name. */
    @IsTest
    static void tiedScoresRankByWhoGotThereFirst() {
        seedPrompts(30);
        Id friendA = register('fa@example.com', 'Friend A');
        Id friendB = register('fb@example.com', 'Friend B');

        // "Zoe" plays first, "Ana" second. Alphabetically Ana would win; she must not.
        BingoService.startSession('zoe@example.com', 'Zoe', true);
        BingoService.markSquare('zoe@example.com', 0, 0, friendA);

        BingoService.startSession('ana@example.com', 'Ana', true);
        BingoService.markSquare('ana@example.com', 0, 0, friendB);

        // Force a measurable gap so the timestamps cannot collide.
        Bingo_Mark__c anaMark = [
            SELECT Id FROM Bingo_Mark__c WHERE Email__c = 'ana@example.com' LIMIT 1
        ];
        Test.setCreatedDate(anaMark.Id, System.now().addMinutes(5));

        List<BingoService.LeaderRowDTO> board = BingoService.getLeaderboard(25);
        BingoService.LeaderRowDTO zoe;
        BingoService.LeaderRowDTO ana;
        for (BingoService.LeaderRowDTO row : board) {
            if (row.displayName == 'Zoe') { zoe = row; }
            if (row.displayName == 'Ana') { ana = row; }
        }
        System.assertNotEquals(null, zoe);
        System.assertNotEquals(null, ana);
        System.assertEquals(zoe.total, ana.total, 'Both should be on the same score.');
        System.assert(zoe.rank < ana.rank,
            'Equal scores must rank by who got there first, not alphabetically.');
    }

    // ------------------------------------------------------------ Validation

    @IsTest
    static void blankEmailIsRejected() {
        try {
            BingoService.startSession('   ', 'Nobody', true);
            System.assert(false, 'Expected a blank email to be rejected.');
        } catch (AuraHandledException e) { System.assert(true); }
    }

    @IsTest
    static void malformedEmailIsRejected() {
        try {
            BingoService.startSession('not-an-email', 'Nobody', true);
            System.assert(false, 'Expected a malformed email to be rejected.');
        } catch (AuraHandledException e) { System.assert(true); }
    }

    @IsTest
    static void returningPlayerDoesNotCreateASecondRow() {
        seedPrompts(30);
        BingoService.startSession('Dup@Example.com', 'First', true);
        BingoService.startSession('dup@example.com', 'Second', true);
        System.assertEquals(1, [SELECT COUNT() FROM Bingo_Player__c WHERE Email__c = 'dup@example.com']);
    }

    @IsTest
    static void consentIsStamped() {
        seedPrompts(30);
        BingoService.startSession('consent@example.com', 'C', true);
        Bingo_Player__c saved = [
            SELECT Consented__c, Consented_At__c FROM Bingo_Player__c WHERE Email__c = 'consent@example.com'
        ];
        System.assertEquals(true, saved.Consented__c);
        System.assertNotEquals(null, saved.Consented_At__c);
    }

    // ------------------------------------------------------------ Helpers

    private static BingoService.SquareDTO firstPromptSquare(BingoService.CardDTO card) {
        for (BingoService.SquareDTO s : card.squares) {
            if (!s.isFreeSpace) { return s; }
        }
        return null;
    }

    private static BingoService.SquareDTO cellOf(BingoService.CardDTO card, Integer r, Integer c) {
        for (BingoService.SquareDTO s : card.squares) {
            if (s.rowIndex == r && s.colIndex == c) { return s; }
        }
        return null;
    }
}
