import json, sys, os
out = sys.argv[1]
def write(name, intro, header, els, steps):
    lines = [json.dumps(header)] + [json.dumps(e) for e in els] + [json.dumps(s) for s in steps]
    open(os.path.join(out, name), 'w').write(intro + "\n\n<whiteboard>\n" + "\n".join(lines) + "\n</whiteboard>\n")

# 2. math
write("math.txt", "here are three formulas worth knowing.",
 {"wb":1,"title":"Three formulas","dir":"TB","sections":[{"id":"q1","title":"Quadratic formula","q":"quadratic formula"},{"id":"q2","title":"An integral","q":"integral"},{"id":"q3","title":"A matrix product","q":"matrix"}]},
 [{"el":"math","id":"quad","sec":"q1","tex":"x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"},
  {"el":"text","id":"qt","sec":"q1","text":"Roots of ax^2 + bx + c = 0","size":"m"},
  {"el":"math","id":"integ","sec":"q2","tex":"\\int_0^1 x^2 \\, dx = \\frac{1}{3}"},
  {"el":"text","id":"it","sec":"q2","text":"Area under the parabola from 0 to 1","size":"m"},
  {"el":"math","id":"mat","sec":"q3","tex":"\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix} \\begin{pmatrix} x \\\\ y \\end{pmatrix} = \\begin{pmatrix} x + 2y \\\\ 3x + 4y \\end{pmatrix}"},
  {"el":"text","id":"mt","sec":"q3","text":"Each row times the column vector","size":"m"}],
 [{"step":1,"show":["quad","qt"],"say":"the quadratic formula gives both roots.","focus":"q1"},
  {"step":2,"show":["integ","it"],"say":"this integral is the area under x squared.","focus":"q2"},
  {"step":3,"show":["mat","mt"],"say":"and a matrix times a vector.","focus":"q3"}])

# 3. code
code = "\n".join([
 "from collections import deque","","def bfs(graph, start, goal):",
 "    \"\"\"Shortest path by edge count.\"\"\"","    queue = deque([start])","    parent = {start: None}","",
 "    while queue:","        node = queue.popleft()","        if node == goal:","            break",
 "        for neighbour in graph.get(node, []):","            if neighbour not in parent:",
 "                parent[neighbour] = node","                queue.append(neighbour)","",
 "    if goal not in parent:","        return None  # unreachable","",
 "    path = []","    node = goal","    while node is not None:","        path.append(node)","        node = parent[node]",
 "    return path[::-1]","","graph = {\"a\": [\"b\", \"c\"], \"b\": [\"d\"], \"c\": [\"d\", \"e\"], \"d\": [\"f\"], \"e\": [\"f\"]}",
 "print(bfs(graph, \"a\", \"f\"))  # ['a', 'b', 'd', 'f']","print(bfs(graph, \"f\", \"a\"))  # None","# 30 lines of breadth-first search"])
assert len(code.split("\n")) == 30, len(code.split("\n"))
write("code.txt", "here's breadth first search in python.",
 {"wb":1,"title":"Breadth-first search in Python","dir":"TB","sections":[{"id":"q1","title":"The code","q":"show bfs in python"}]},
 [{"el":"code","id":"src","sec":"q1","lang":"python","text":code,"hl":[8,9,12]},
  {"el":"callout","id":"c","sec":"q1","target":"src","style":"tip","text":"The parent map doubles as the visited set."}],
 [{"step":1,"show":["src"],"hl":["src"],"say":"a queue walks the graph level by level.","focus":"q1"},
  {"step":2,"show":["c"],"say":"the parent map is also the visited set.","focus":"q1"}])

# 4. long multi-section board
secs=[{"id":"agenda","title":"Agenda"}]
names=["Parsing","Type checking","Optimisation","Code generation","Linking","Loading"]
for i,n in enumerate(names): secs.append({"id":f"q{i+1}","title":n,"q":n.lower()})
secs.append({"id":"recap","title":"Recap"})
els=[{"el":"list","id":"ag","sec":"agenda","title":"Stages","items":names,"ordered":True}]
steps=[{"step":1,"show":["ag"],"say":"six stages from source to a running program.","focus":"agenda"}]
for i,n in enumerate(names):
    s=f"q{i+1}"
    els += [{"el":"box","id":f"{s}in","sec":s,"text":f"{n} input","shape":"round","color":"blue"},
            {"el":"box","id":f"{s}out","sec":s,"text":f"{n} output","shape":"rect","color":"green"},
            {"el":"arrow","id":f"{s}a","sec":s,"from":f"{s}in","to":f"{s}out","text":"transforms"},
            {"el":"list","id":f"{s}l","sec":s,"title":f"{n} notes","items":[f"{n} step one",f"{n} step two",f"{n} step three"],"ordered":False},
            {"el":"text","id":f"{s}t","sec":s,"text":f"Why {n.lower()} matters: it keeps the next stage simple.","size":"s"},
            {"el":"table","id":f"{s}tb","sec":s,"cols":["Input","Output","Cost"],"rows":[[f"{n} a","result a","low"],[f"{n} b","result b","medium"],[f"{n} c","result c","high"],[f"{n} d","result d","low"]]},
            {"el":"callout","id":f"{s}c","sec":s,"target":f"{s}out","style":"info","text":f"{n} errors are reported with a line number."}]
    steps.append({"step":i+2,"show":[f"{s}in",f"{s}out",f"{s}a",f"{s}l",f"{s}t",f"{s}tb",f"{s}c"],"say":f"{n.lower()} turns its input into output.","focus":s})
els.append({"el":"list","id":"rc","sec":"recap","title":"Key points","items":["Each stage has one job","Errors surface early","The linker joins the pieces"],"ordered":False})
steps.append({"step":len(names)+2,"show":["rc"],"say":"each stage has one job.","focus":"recap"})
write("long.txt","here's the whole compiler pipeline.",
 {"wb":1,"title":"From source code to a running program","dir":"TB","sections":secs}, els, steps)

# 5. charts
write("chart.txt","here are the numbers.",
 {"wb":1,"title":"Language popularity","dir":"TB","sections":[{"id":"q1","title":"Survey results","q":"popularity"},{"id":"q2","title":"Trend and share","q":"trend"}]},
 [{"el":"chart","id":"bar","sec":"q1","kind":"bar","title":"Developers using it (%)","data":[["Python",51],["JavaScript",62],["TypeScript",38],["Rust",13],["Go",14]]},
  {"el":"table","id":"tab","sec":"q1","cols":["Language","Share","Change"],"rows":[["Python","51%","+3"],["JavaScript","62%","-1"],["Rust","13%","+2"]]},
  {"el":"chart","id":"line","sec":"q2","kind":"line","title":"Rust usage by year","data":[["2020",5],["2021",7],["2022",9],["2023",11],["2024",13]]},
  {"el":"chart","id":"pie","sec":"q2","kind":"pie","title":"Backend share","data":[["Java",30],["Python",28],["Go",17],["Other",25]]}],
 [{"step":1,"show":["bar","tab"],"say":"javascript still leads.","focus":"q1"},
  {"step":2,"show":["line","pie"],"say":"rust keeps growing.","focus":"q2"}])

# 6. tall: the long board with a 30-line code block in every section (taller than A4 proportions → paged)
tall_els = list(els)
for i,n in enumerate(names):
    s=f"q{i+1}"
    tall_els.append({"el":"code","id":f"{s}code","sec":s,"lang":"python","text":"\n".join(f"step_{k} = {n.lower().replace(' ','_')}(step_{k-1})  # line {k}" for k in range(1,31))})
    steps[i+1]["show"].append(f"{s}code")
write("tall.txt","here's the whole pipeline, with code.",
 {"wb":1,"title":"Compiler pipeline with code","dir":"TB","sections":secs}, tall_els, steps)
