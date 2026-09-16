/**
 * Public entry point for the Dreamforce Networking Bingo site.
 *
 * ── Why this design looks unusual ────────────────────────────────────────────
 * Experience Cloud guest users can INSERT and READ, but can never UPDATE:
 * DML on a guest profile raises
 *     System.TypeException: DML operation UPDATE not allowed on <Object>
 * That is an object-CRUD check below the sharing layer, so `without sharing`
 * does not help and guest profiles cannot be granted Edit. Guests also cannot
 * insert a record referencing a parent they lack access to
 * (INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY).
 *
 * Consequences, both deliberate:
 *   1. The 5x5 layout is DERIVED from the email, not stored. The same email
 *      always rebuilds the identical card, so a refresh restores the board with
 *      no card or square records to create.
 *   2. Marking and un-marking are both INSERTs into Bingo_Mark__c, which has no
 *      lookup fields. Current state is the latest row per cell.
 *
 * `without sharing` is still required so staff-side calls bypass record sharing.
 */
public without sharing class BingoService {

    private static final Integer GRID             = 5;
    private static final Integer FREE_ROW         = 2;
    private static final Integer FREE_COL         = 2;
    private static final Integer PROMPTS_PER_CARD = 24;
    public  static final String  FREE_SPACE_TEXT  = 'FREE SPACE — make a connection here!';

    // Scoring. Derived on read, never stored: guests cannot update a running total,
    // so score is a pure function of the marks log.
    private static final Integer POINTS_PER_SQUARE = 1;    // max 24
    private static final Integer POINTS_PER_LINE   = 5;    // 12 possible lines
    private static final Integer POINTS_BLACKOUT   = 25;
    private static final Integer POINTS_PER_HELP   = 1;    // uncapped, rewards being helpful

    // ---------------------------------------------------------------- DTOs

    public class SquareDTO {
        @AuraEnabled public Integer rowIndex;
        @AuraEnabled public Integer colIndex;
        @AuraEnabled public String  promptText;
        @AuraEnabled public Boolean isFreeSpace;
        @AuraEnabled public Boolean isMarked;
        @AuraEnabled public String  metPersonName;
    }

    public class CardDTO {
        @AuraEnabled public String  email;
        @AuraEnabled public String  displayName;
        @AuraEnabled public List<SquareDTO> squares;
        @AuraEnabled public Boolean bingoAchieved;
        @AuraEnabled public Boolean blackout;
        @AuraEnabled public Integer markedCount;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public ScoreDTO score;
    }

    public class PlayerRefDTO {
        @AuraEnabled public String playerId;      // opaque handle; the email never leaves the server
        @AuraEnabled public String displayName;
    }

    public class ScoreDTO {
        @AuraEnabled public Integer squares;
        @AuraEnabled public Integer lines;
        @AuraEnabled public Integer helped;
        @AuraEnabled public Integer total;
    }

    public class LeaderRowDTO {
        @AuraEnabled public Integer rank;
        @AuraEnabled public String  displayName;
        @AuraEnabled public Integer squares;
        @AuraEnabled public Integer lines;
        @AuraEnabled public Integer helped;
        @AuraEnabled public Integer total;
        @AuraEnabled public Boolean blackout;
    }

    // ------------------------------------------------------------ Entry points

    @AuraEnabled
    public static CardDTO startSession(String email, String displayName, Boolean consented) {
        String key = normalizeEmail(email);
        registerPlayer(key, displayName, consented);
        return buildCard(key);
    }

    /** Typeahead over registered players. Returns an opaque id, never an email. */
    @AuraEnabled(cacheable=false)
    public static List<PlayerRefDTO> searchPlayers(String term, String excludeEmail) {
        List<PlayerRefDTO> results = new List<PlayerRefDTO>();
        if (String.isBlank(term) || term.trim().length() < 2) {
            return results;
        }
        String pattern = '%' + term.trim() + '%';
        String me   = String.isBlank(excludeEmail) ? '' : excludeEmail.trim().toLowerCase();

        for (Bingo_Player__c p : [
            SELECT Id, Display_Name__c FROM Bingo_Player__c
            WHERE Display_Name__c LIKE :pattern AND Email__c != :me
            ORDER BY Display_Name__c
            LIMIT 10
        ]) {
            PlayerRefDTO ref = new PlayerRefDTO();
            ref.playerId    = p.Id;
            ref.displayName = p.Display_Name__c;
            results.add(ref);
        }
        return results;
    }

    @AuraEnabled
    public static CardDTO markSquare(String email, Integer rowIndex, Integer colIndex, String metPlayerId) {
        String key = normalizeEmail(email);
        validateCell(rowIndex, colIndex);
        if (isFreeSpace(rowIndex, colIndex)) {
            throw new AuraHandledException('The free space is already yours.');
        }
        if (String.isBlank(metPlayerId)) {
            throw new AuraHandledException('Pick the registered player you met.');
        }

        List<Bingo_Player__c> met = [
            SELECT Id, Email__c, Display_Name__c FROM Bingo_Player__c WHERE Id = :metPlayerId LIMIT 1
        ];
        if (met.isEmpty()) {
            throw new AuraHandledException('That player is not registered yet — ask them to scan the QR first.');
        }
        if (met[0].Email__c == key) {
            throw new AuraHandledException('You can\'t mark a square by meeting yourself.');
        }

        Bingo_Mark__c mark = new Bingo_Mark__c(
            Email__c            = key,
            Row__c              = rowIndex,
            Col__c              = colIndex,
            Met_Person_Name__c  = met[0].Display_Name__c,
            Met_Player_Email__c = met[0].Email__c,
            Prompt_Text__c      = promptAt(layoutFor(key), rowIndex, colIndex),
            Cleared__c          = false
        );
        insert mark;
        return buildCard(key, mark);
    }

    /** An un-mark is an insert too — guests can neither update nor delete. */
    @AuraEnabled
    public static CardDTO unmarkSquare(String email, Integer rowIndex, Integer colIndex) {
        String key = normalizeEmail(email);
        validateCell(rowIndex, colIndex);
        if (isFreeSpace(rowIndex, colIndex)) {
            throw new AuraHandledException('The free space can\'t be cleared.');
        }
        Bingo_Mark__c mark = new Bingo_Mark__c(
            Email__c   = key,
            Row__c     = rowIndex,
            Col__c     = colIndex,
            Cleared__c = true
        );
        insert mark;
        return buildCard(key, mark);
    }

    // ------------------------------------------------------------ Player

    private static void registerPlayer(String key, String displayName, Boolean consented) {
        Bingo_Player__c player = new Bingo_Player__c(
            Email__c        = key,
            Display_Name__c = String.isBlank(displayName) ? null : displayName.trim().abbreviate(120),
            Consented__c    = consented == true
        );
        if (consented == true) {
            player.Consented_At__c = System.now();
        }
        try {
            insert player;
        } catch (DmlException e) {
            // Email__c is unique. A returning player already has a row and a guest
            // cannot update it, so reusing the existing row is the intended outcome.
            if (e.getDmlType(0) != StatusCode.DUPLICATE_VALUE) {
                throw e;
            }
        }
    }

    // ------------------------------------------------------------ Layout

    private static List<String> promptPoolCache;
    private static Map<String, List<String>> layoutCache = new Map<String, List<String>>();

    /**
     * Deterministically derives the 24 prompts for an email.
     *
     * Ordering the pool by Id and seeding the shuffle from the email means the
     * same email always produces the same card, on any device — which is what
     * makes a refresh safe without storing the layout anywhere.
     *
     * NOTE: the prompt pool must be frozen once play begins. Adding, removing or
     * deactivating a prompt reshuffles everybody's card.
     */
    @TestVisible
    private static List<String> layoutFor(String email) {
        if (layoutCache.containsKey(email)) {
            return layoutCache.get(email);
        }
        if (promptPoolCache == null) {
            promptPoolCache = new List<String>();
            for (Bingo_Prompt__c p : [
                SELECT Id, Text__c FROM Bingo_Prompt__c WHERE Active__c = true ORDER BY Id
            ]) {
                promptPoolCache.add(p.Text__c);
            }
        }
        if (promptPoolCache.size() < PROMPTS_PER_CARD) {
            throw new AuraHandledException(
                'Only ' + promptPoolCache.size() + ' active prompts exist; ' + PROMPTS_PER_CARD + ' are needed.'
            );
        }

        List<String> texts = new List<String>(promptPoolCache);

        // Seeded Fisher-Yates. A plain LCG keeps every intermediate inside Long range.
        Long seed = seedFrom(email);
        for (Integer i = texts.size() - 1; i > 0; i--) {
            seed = Math.mod(seed * 1103515245L + 12345L, 2147483648L);
            Integer j = (Integer) Math.mod(seed, i + 1);
            String swap = texts[i];
            texts[i] = texts[j];
            texts[j] = swap;
        }

        List<String> chosen = new List<String>();
        for (Integer i = 0; i < PROMPTS_PER_CARD; i++) {
            chosen.add(texts[i]);
        }
        layoutCache.put(email, chosen);
        return chosen;
    }

    private static Long seedFrom(String email) {
        Long hash = 7;
        for (Integer i = 0; i < email.length(); i++) {
            hash = Math.mod(hash * 31 + email.charAt(i), 2147483648L);
        }
        return hash;
    }

    /** Maps a grid cell to its prompt, skipping over the free space. */
    private static String promptAt(List<String> layout, Integer rowIndex, Integer colIndex) {
        if (isFreeSpace(rowIndex, colIndex)) {
            return FREE_SPACE_TEXT;
        }
        Integer flat     = rowIndex * GRID + colIndex;
        Integer freeFlat = FREE_ROW * GRID + FREE_COL;
        return layout[flat > freeFlat ? flat - 1 : flat];
    }

    // ------------------------------------------------------------ Read + win

    private static CardDTO buildCard(String key) {
        return buildCard(key, null);
    }

    /**
     * `pending` is a row written earlier in this same transaction. Guest sharing
     * recalculation is asynchronous, so a guest cannot reliably re-query a record
     * it just inserted — merging it in memory makes the response correct
     * immediately instead of depending on a read-after-write.
     */
    private static CardDTO buildCard(String key, Bingo_Mark__c pending) {
        List<String> layout = layoutFor(key);

        // Latest row per cell wins; a Cleared__c row un-marks it.
        Map<String, Bingo_Mark__c> latest = new Map<String, Bingo_Mark__c>();
        for (Bingo_Mark__c m : [
            SELECT Row__c, Col__c, Met_Person_Name__c, Cleared__c
            FROM Bingo_Mark__c WHERE Email__c = :key
            ORDER BY CreatedDate ASC, Id ASC
        ]) {
            latest.put(Integer.valueOf(m.Row__c) + '-' + Integer.valueOf(m.Col__c), m);
        }
        if (pending != null) {
            latest.put(Integer.valueOf(pending.Row__c) + '-' + Integer.valueOf(pending.Col__c), pending);
        }

        List<Bingo_Player__c> players = [
            SELECT Display_Name__c FROM Bingo_Player__c WHERE Email__c = :key LIMIT 1
        ];

        CardDTO dto     = new CardDTO();
        dto.email       = key;
        dto.displayName = players.isEmpty() ? null : players[0].Display_Name__c;
        dto.squares     = new List<SquareDTO>();
        dto.totalCount  = PROMPTS_PER_CARD;
        dto.markedCount = 0;

        Set<String> marked = new Set<String>();
        for (Integer r = 0; r < GRID; r++) {
            for (Integer c = 0; c < GRID; c++) {
                String cell            = r + '-' + c;
                Bingo_Mark__c m        = latest.get(cell);
                Boolean isFree         = isFreeSpace(r, c);
                Boolean isOn           = isFree || (m != null && m.Cleared__c != true);

                SquareDTO sd     = new SquareDTO();
                sd.rowIndex      = r;
                sd.colIndex      = c;
                sd.isFreeSpace   = isFree;
                sd.promptText    = promptAt(layout, r, c);
                sd.isMarked      = isOn;
                sd.metPersonName = (isOn && !isFree && m != null) ? m.Met_Person_Name__c : null;
                dto.squares.add(sd);

                if (isOn) {
                    marked.add(cell);
                    if (!isFree) { dto.markedCount++; }
                }
            }
        }

        dto.bingoAchieved = hasLine(marked);
        dto.blackout      = (dto.markedCount == PROMPTS_PER_CARD);

        ScoreDTO score = new ScoreDTO();
        score.squares  = dto.markedCount;
        score.lines    = countLines(marked);
        score.helped   = helperPointsFor(key);
        score.total    = scoreOf(score.squares, score.lines, dto.blackout, score.helped);
        dto.score      = score;
        return dto;
    }

    /**
     * Counts how many players currently have an in-effect mark naming this player.
     * Must look at the latest row per (player, cell): a plain COUNT would still see
     * the original mark after an un-mark appended a Cleared row on top of it.
     */
    private static Integer helperPointsFor(String key) {
        List<Bingo_Mark__c> credits = [
            SELECT Email__c FROM Bingo_Mark__c WHERE Met_Player_Email__c = :key
        ];
        if (credits.isEmpty()) {
            return 0;
        }
        Set<String> givers = new Set<String>();
        for (Bingo_Mark__c m : credits) {
            givers.add(m.Email__c);
        }

        Map<String, Bingo_Mark__c> latest = new Map<String, Bingo_Mark__c>();
        for (Bingo_Mark__c m : [
            SELECT Email__c, Row__c, Col__c, Cleared__c, Met_Player_Email__c
            FROM Bingo_Mark__c WHERE Email__c IN :givers
            ORDER BY CreatedDate ASC, Id ASC
        ]) {
            latest.put(
                m.Email__c + '|' + Integer.valueOf(m.Row__c) + '-' + Integer.valueOf(m.Col__c), m);
        }

        Integer points = 0;
        for (Bingo_Mark__c m : latest.values()) {
            if (m.Cleared__c != true && m.Met_Player_Email__c == key) {
                points++;
            }
        }
        return points;
    }

    private static Integer scoreOf(Integer squares, Integer lines, Boolean blackout, Integer helped) {
        return (squares * POINTS_PER_SQUARE)
             + (lines * POINTS_PER_LINE)
             + (blackout == true ? POINTS_BLACKOUT : 0)
             + (helped * POINTS_PER_HELP);
    }

    /** How many of the 12 possible lines are complete. */
    @TestVisible
    private static Integer countLines(Set<String> marked) {
        Integer lines = 0;
        for (Integer i = 0; i < GRID; i++) {
            Boolean rowFull = true;
            Boolean colFull = true;
            for (Integer j = 0; j < GRID; j++) {
                if (!marked.contains(i + '-' + j)) { rowFull = false; }
                if (!marked.contains(j + '-' + i)) { colFull = false; }
            }
            if (rowFull) { lines++; }
            if (colFull) { lines++; }
        }
        Boolean downRight = true;
        Boolean downLeft  = true;
        for (Integer i = 0; i < GRID; i++) {
            if (!marked.contains(i + '-' + i))              { downRight = false; }
            if (!marked.contains(i + '-' + (GRID - 1 - i))) { downLeft  = false; }
        }
        if (downRight) { lines++; }
        if (downLeft)  { lines++; }
        return lines;
    }

    /**
     * Leaderboard across every player.
     *
     * Deliberately does NOT derive anybody's card layout: a completed line depends
     * only on WHICH cells are marked, not on which prompt sits in them. So this is
     * two queries and some in-memory counting, regardless of player count.
     */
    @AuraEnabled(cacheable=false)
    public static List<LeaderRowDTO> getLeaderboard(Integer maxRows) {
        Integer cap = (maxRows == null || maxRows <= 0) ? 25 : maxRows;

        // email -> cell -> effective (latest) mark
        Map<String, Map<String, Bingo_Mark__c>> byPlayer = new Map<String, Map<String, Bingo_Mark__c>>();
        for (Bingo_Mark__c m : [
            SELECT Email__c, Row__c, Col__c, Cleared__c, Met_Player_Email__c
            FROM Bingo_Mark__c
            ORDER BY CreatedDate ASC, Id ASC
        ]) {
            if (!byPlayer.containsKey(m.Email__c)) {
                byPlayer.put(m.Email__c, new Map<String, Bingo_Mark__c>());
            }
            byPlayer.get(m.Email__c).put(
                Integer.valueOf(m.Row__c) + '-' + Integer.valueOf(m.Col__c), m);
        }

        // Helper points come only from marks that are still in effect — un-marking
        // a square takes back the point it gave.
        Map<String, Integer> helped = new Map<String, Integer>();
        for (Map<String, Bingo_Mark__c> cells : byPlayer.values()) {
            for (Bingo_Mark__c m : cells.values()) {
                if (m.Cleared__c == true || String.isBlank(m.Met_Player_Email__c)) { continue; }
                Integer current = helped.containsKey(m.Met_Player_Email__c)
                    ? helped.get(m.Met_Player_Email__c) : 0;
                helped.put(m.Met_Player_Email__c, current + 1);
            }
        }

        Map<String, String> names = new Map<String, String>();
        for (Bingo_Player__c p : [SELECT Email__c, Display_Name__c FROM Bingo_Player__c]) {
            names.put(p.Email__c, p.Display_Name__c);
        }

        Set<String> everyone = new Set<String>();
        everyone.addAll(byPlayer.keySet());
        everyone.addAll(helped.keySet());

        List<LeaderRowDTO> rows = new List<LeaderRowDTO>();
        for (String playerEmail : everyone) {
            Set<String> marked = new Set<String>{ FREE_ROW + '-' + FREE_COL };
            Integer squares = 0;
            if (byPlayer.containsKey(playerEmail)) {
                for (String cell : byPlayer.get(playerEmail).keySet()) {
                    if (byPlayer.get(playerEmail).get(cell).Cleared__c == true) { continue; }
                    marked.add(cell);
                    squares++;
                }
            }
            LeaderRowDTO row = new LeaderRowDTO();
            row.displayName = names.containsKey(playerEmail) ? names.get(playerEmail) : 'Anonymous';
            row.squares     = squares;
            row.lines       = countLines(marked);
            row.helped      = helped.containsKey(playerEmail) ? helped.get(playerEmail) : 0;
            row.blackout    = (squares == PROMPTS_PER_CARD);
            row.total       = scoreOf(row.squares, row.lines, row.blackout, row.helped);
            rows.add(row);
        }

        rows.sort(new ByScoreDesc());
        List<LeaderRowDTO> top = new List<LeaderRowDTO>();
        for (Integer i = 0; i < rows.size() && i < cap; i++) {
            rows[i].rank = i + 1;
            top.add(rows[i]);
        }
        return top;
    }

    private class ByScoreDesc implements Comparator<LeaderRowDTO> {
        public Integer compare(LeaderRowDTO a, LeaderRowDTO b) {
            if (a.total != b.total)     { return b.total - a.total; }
            if (a.squares != b.squares) { return b.squares - a.squares; }
            return (a.displayName == null ? '' : a.displayName)
                .compareTo(b.displayName == null ? '' : b.displayName);
        }
    }

    /** Five rows, five columns, two diagonals. The free space counts as marked. */
    @TestVisible
    private static Boolean hasLine(Set<String> marked) {
        for (Integer i = 0; i < GRID; i++) {
            Boolean rowFull = true;
            Boolean colFull = true;
            for (Integer j = 0; j < GRID; j++) {
                if (!marked.contains(i + '-' + j)) { rowFull = false; }
                if (!marked.contains(j + '-' + i)) { colFull = false; }
            }
            if (rowFull || colFull) { return true; }
        }
        Boolean downRight = true;
        Boolean downLeft  = true;
        for (Integer i = 0; i < GRID; i++) {
            if (!marked.contains(i + '-' + i))              { downRight = false; }
            if (!marked.contains(i + '-' + (GRID - 1 - i))) { downLeft  = false; }
        }
        return downRight || downLeft;
    }

    // ------------------------------------------------------------- Helpers

    private static Boolean isFreeSpace(Integer rowIndex, Integer colIndex) {
        return rowIndex == FREE_ROW && colIndex == FREE_COL;
    }

    private static void validateCell(Integer rowIndex, Integer colIndex) {
        if (rowIndex == null || colIndex == null
            || rowIndex < 0 || rowIndex >= GRID || colIndex < 0 || colIndex >= GRID) {
            throw new AuraHandledException('That square is not on the board.');
        }
    }

    @TestVisible
    private static String normalizeEmail(String email) {
        if (String.isBlank(email)) {
            throw new AuraHandledException('Please enter your email address.');
        }
        String normalized = email.trim().toLowerCase();
        if (!Pattern.matches('^[^@\\s]+@[^@\\s.]+\\.[^@\\s]+$', normalized)) {
            throw new AuraHandledException('That doesn\'t look like a valid email address.');
        }
        return normalized;
    }
}
