import pdfplumber, json, re, collections
PDF="/Users/rafaelhernandez/Downloads/Dreamforce_2026_Networking_Bingo_20_Cards_CLEAN.pdf"
L,R,T,B = 0.145, 0.878, 0.255, 0.885
cards=[]
with pdfplumber.open(PDF) as pdf:
    for page in pdf.pages:
        W,H=page.width,page.height
        left,right,top,bot = L*W,R*W,T*H,B*H
        cw,ch=(right-left)/5,(bot-top)/5
        grid=collections.defaultdict(list)
        for w in page.extract_words():
            cx,cy=(w['x0']+w['x1'])/2,(w['top']+w['bottom'])/2
            if not (left<=cx<right and top<=cy<bot): continue
            grid[(int((cy-top)//ch), int((cx-left)//cw))].append((cy,cx,w['text']))
        cards.append([[re.sub(r'\s+',' ',' '.join(t[2] for t in sorted(grid.get((r,c),[]),key=lambda t:(round(t[0]/5),t[1])))).strip()
                       for c in range(5)] for r in range(5)])
json.dump(cards,open('/tmp/bingo_cards.json','w'),indent=1)
pool=collections.Counter()
for card in cards:
    for row in card:
        for cell in row:
            if cell and 'FREE SPACE' not in cell: pool[cell]+=1
print("cards:",len(cards),"| unique prompts:",len(pool))
print("\nCARD 1 (compare against the image):")
for row in cards[0]:
    for cell in row: print("   -",cell)
    print("   "+"."*30)
print("\nPOOL:")
for t,n in sorted(pool.items(), key=lambda kv:-kv[1]): print(f"  {n:>2}x  {t}")
