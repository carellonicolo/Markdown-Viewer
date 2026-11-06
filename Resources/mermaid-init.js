// I diagrammi vengono sempre disegnati con il tema chiaro: in modalità scura li inverte il CSS
// a schermo, mentre in stampa/PDF restano chiari e leggibili.
mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'default' });
// L'app attende questa promessa prima di ripristinare la posizione di lettura.
window.mermaidReady = mermaid.run({ querySelector: 'pre.mermaid' });
