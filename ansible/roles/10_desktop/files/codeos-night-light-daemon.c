/*
 * Vigia da luz noturna do CodeOS (autostart da sessão): aplica a temperatura de cor de cada monitor na
 * curva de gamma do CRTC dele (RandR). É a parte que fica rodando o tempo todo; a janela de configuração
 * continua em codeos-night-light (Python), que grava ~/.config/codeos/night-light.json. Em Python o
 * vigia ocupava ~16 MB parado; aqui, ~2 MB.
 *
 * Mesma regra do codeos-night-light: modo off/always/schedule, transição de 30 min no começo e no fim do
 * horário, temperatura própria por monitor e prévia (preview_until) enquanto a janela ajusta a cor. Relê a
 * configuração quando o arquivo muda e reaplica quando outra coisa troca a curva (mudança de modo).
 *
 *   gcc -O2 -o codeos-night-light-daemon codeos-night-light-daemon.c \
 *       $(pkg-config --cflags --libs json-glib-1.0 xrandr x11) -lm
 */
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <json-glib/json-glib.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define DIA            6500
#define TRANSICAO_MIN  30
#define MAX_SAIDAS     8

typedef struct {
    gchar   *modo;      /* off, always, schedule */
    gint     inicio;    /* minutos do dia */
    gint     fim;
    gint     padrao;    /* temperatura padrão */
    gdouble  previa_ate;
    JsonObject *monitores;
    JsonParser *parser;
} Config;

static Display *d;
static volatile sig_atomic_t sair = 0;

static gint
minutos (const gchar *hhmm, gint padrao)
{
    gint h, m;
    if (hhmm != NULL && sscanf (hhmm, "%d:%d", &h, &m) == 2)
        return h * 60 + m;
    return padrao;
}

static void
ler_config (const gchar *caminho, Config *c)
{
    JsonObject *raiz = NULL;

    g_free (c->modo);
    if (c->parser != NULL)
        g_object_unref (c->parser);
    c->modo = g_strdup ("schedule");
    c->inicio = 19 * 60;
    c->fim = 6 * 60 + 30;
    c->padrao = 4000;
    c->previa_ate = 0;
    c->monitores = NULL;
    c->parser = json_parser_new ();
    if (json_parser_load_from_file (c->parser, caminho, NULL)
        && JSON_NODE_HOLDS_OBJECT (json_parser_get_root (c->parser)))
        raiz = json_node_get_object (json_parser_get_root (c->parser));
    if (raiz == NULL)
        return;
    if (json_object_has_member (raiz, "mode")) {
        g_free (c->modo);
        c->modo = g_strdup (json_object_get_string_member (raiz, "mode"));
    }
    if (json_object_has_member (raiz, "start"))
        c->inicio = minutos (json_object_get_string_member (raiz, "start"), c->inicio);
    if (json_object_has_member (raiz, "end"))
        c->fim = minutos (json_object_get_string_member (raiz, "end"), c->fim);
    if (json_object_has_member (raiz, "default"))
        c->padrao = (gint) json_object_get_int_member (raiz, "default");
    if (json_object_has_member (raiz, "preview_until"))
        c->previa_ate = json_object_get_double_member (raiz, "preview_until");
    if (json_object_has_member (raiz, "monitors"))
        c->monitores = json_object_get_object_member (raiz, "monitors");
}

static void
monitor_cfg (const Config *c, const gchar *nome, gboolean *ligado, gint *temperatura)
{
    JsonObject *m = c->monitores != NULL && json_object_has_member (c->monitores, nome)
                    ? json_object_get_object_member (c->monitores, nome) : NULL;
    *ligado = m == NULL || !json_object_has_member (m, "enabled") || json_object_get_boolean_member (m, "enabled");
    *temperatura = m != NULL && json_object_has_member (m, "temperature")
                   ? (gint) json_object_get_int_member (m, "temperature") : c->padrao;
}

/* multiplicadores R, G, B do branco numa temperatura, normalizados para 6500 K = branco */
static void
bruto (gdouble k, gdouble cor[3])
{
    gdouble t = k / 100;
    cor[0] = t <= 66 ? 255 : 329.698727446 * pow (t - 60, -0.1332047592);
    cor[1] = t <= 66 ? 99.4708025861 * log (t) - 161.1195681661 : 288.1221695283 * pow (t - 60, -0.0755148492);
    cor[2] = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log (t - 10) - 305.0447927307);
    for (int i = 0; i < 3; i++)
        cor[i] = CLAMP (cor[i], 0.0, 255.0);
}

static void
rgb (gint kelvin, gdouble mult[3])
{
    gdouble alvo[3], ref[3];
    bruto (kelvin, alvo);
    bruto (DIA, ref);
    for (int i = 0; i < 3; i++)
        mult[i] = MIN (1.0, alvo[i] / ref[i]);
}

/* 0 = dia (sem filtro), 1 = noite (temperatura escolhida), com transição suave */
static gdouble
intensidade (const Config *c)
{
    time_t agora = time (NULL);
    struct tm tm;
    gdouble t, dur, desde, entrada, saida;

    if (c->previa_ate > (gdouble) agora)
        return 1.0;
    if (g_strcmp0 (c->modo, "off") == 0)
        return 0.0;
    if (g_strcmp0 (c->modo, "always") == 0)
        return 1.0;
    localtime_r (&agora, &tm);
    t = tm.tm_hour * 60 + tm.tm_min + tm.tm_sec / 60.0;
    dur = fmod (c->fim - c->inicio + 1440, 1440);
    desde = fmod (t - c->inicio + 1440, 1440);
    if (desde >= dur)
        return 0.0;
    entrada = MIN (1.0, desde / TRANSICAO_MIN);
    saida = MIN (1.0, (dur - desde) / TRANSICAO_MIN);
    return MIN (entrada, saida);
}

static void
topo_esperado (gint kelvin, gushort topo[3])
{
    gdouble mult[3];
    rgb (kelvin, mult);
    for (int i = 0; i < 3; i++)
        topo[i] = (gushort) MIN (65535, (gint) (65535 * mult[i]));
}

static void
aplicar (RRCrtc crtc, gint kelvin)
{
    gint n = XRRGetCrtcGammaSize (d, crtc);
    XRRCrtcGamma *g;
    gdouble mult[3];

    if (n < 2)
        return;
    rgb (kelvin, mult);
    g = XRRAllocGamma (n);
    for (gint i = 0; i < n; i++) {
        gdouble base = (gdouble) i / (n - 1) * 65535;
        g->red[i] = (gushort) MIN (65535, (gint) (base * mult[0]));
        g->green[i] = (gushort) MIN (65535, (gint) (base * mult[1]));
        g->blue[i] = (gushort) MIN (65535, (gint) (base * mult[2]));
    }
    XRRSetCrtcGamma (d, crtc, g);
    XRRFreeGamma (g);
    XSync (d, False);
}

static gboolean
curva_trocada (RRCrtc crtc, const gushort topo[3])
{
    XRRCrtcGamma *g = XRRGetCrtcGamma (d, crtc);
    gboolean trocada = TRUE;
    if (g != NULL && g->size > 0)
        trocada = g->red[g->size - 1] != topo[0] || g->green[g->size - 1] != topo[1]
                  || g->blue[g->size - 1] != topo[2];
    if (g != NULL)
        XRRFreeGamma (g);
    return trocada;
}

/* chama f(nome, crtc) para cada saída conectada e ligada */
static void
para_cada_saida (void (*f) (const gchar *, RRCrtc, gpointer), gpointer dados)
{
    Window raiz = DefaultRootWindow (d);
    XRRScreenResources *rec = XRRGetScreenResourcesCurrent (d, raiz);
    if (rec == NULL)
        return;
    for (int i = 0; i < rec->noutput; i++) {
        XRROutputInfo *info = XRRGetOutputInfo (d, rec, rec->outputs[i]);
        if (info != NULL && info->connection == RR_Connected && info->crtc != None)
            f (info->name, info->crtc, dados);
        if (info != NULL)
            XRRFreeOutputInfo (info);
    }
    XRRFreeScreenResources (rec);
}

typedef struct { RRCrtc crtc; gint kelvin; } Aplicado;
static Aplicado aplicados[MAX_SAIDAS];

static void
atualizar_saida (const gchar *nome, RRCrtc crtc, gpointer dados)
{
    const Config *c = ((gpointer *) dados)[0];
    gdouble f = *(gdouble *) ((gpointer *) dados)[1];
    gboolean ligado;
    gint alvo, kelvin, livre = -1, i;
    gushort topo[3];

    monitor_cfg (c, nome, &ligado, &alvo);
    kelvin = ligado ? (gint) lround (DIA - f * (DIA - alvo)) : DIA;
    topo_esperado (kelvin, topo);
    for (i = 0; i < MAX_SAIDAS; i++) {
        if (aplicados[i].crtc == crtc)
            break;
        if (aplicados[i].crtc == 0 && livre < 0)
            livre = i;
    }
    if (i == MAX_SAIDAS)
        i = livre >= 0 ? livre : 0;
    /* reaplica também quando a curva foi trocada por fora (mudança de modo do monitor) */
    if (aplicados[i].crtc != crtc || aplicados[i].kelvin != kelvin || curva_trocada (crtc, topo)) {
        aplicar (crtc, kelvin);
        aplicados[i].crtc = crtc;
        aplicados[i].kelvin = kelvin;
    }
}

static void
zerar_saida (const gchar *nome, RRCrtc crtc, gpointer dados)
{
    aplicar (crtc, DIA);
}

static void
ao_sinal (int s)
{
    sair = 1;
}

int
main (void)
{
    gchar *caminho = g_build_filename (g_get_user_config_dir (), "codeos", "night-light.json", NULL);
    Config c = { 0 };
    time_t mtime = -1, proximo = 0;
    struct sigaction sa = { 0 };

    d = XOpenDisplay (NULL);
    if (d == NULL)
        return 1;
    sa.sa_handler = ao_sinal;
    sigaction (SIGTERM, &sa, NULL);
    sigaction (SIGINT, &sa, NULL);
    ler_config (caminho, &c);

    while (!sair) {
        struct stat st;
        time_t m = stat (caminho, &st) == 0 ? st.st_mtime : 0;
        time_t agora = time (NULL);

        if (m != mtime) {
            mtime = m;
            ler_config (caminho, &c);
            proximo = 0;
        }
        if (agora >= proximo || c.previa_ate > (gdouble) agora - 2) {
            gdouble f = intensidade (&c);
            gpointer dados[2] = { &c, &f };
            para_cada_saida (atualizar_saida, dados);
            proximo = agora + 30;
        }
        sleep (1);
    }
    /* ao sair (fim da sessão), as telas voltam sem filtro */
    para_cada_saida (zerar_saida, NULL);
    XCloseDisplay (d);
    return 0;
}
