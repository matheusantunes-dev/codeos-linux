/*
 * Vigia do papel de parede do CodeOS (autostart da sessão): com a chave "Aplicar em todas as telas"
 * ligada (xfce4-desktop /codeos/all-displays), o papel de parede escolhido numa tela vai para todas as
 * telas e áreas de trabalho. É a parte que fica rodando o tempo todo; a janela com a chave continua em
 * codeos-wallpaper (Python). Em Python o vigia ocupava ~20 MB parado; aqui, ~2 MB.
 *
 * Também vigia os monitores: o xfdesktop só tem papel de parede para nomes de saída que já estão na
 * configuração (os padrões do CodeOS listam HDMI-1, eDP-1, DP-1...). Uma saída de nome novo (por
 * exemplo HDMI-1-2, a da placa NVIDIA num notebook híbrido) caía no papel de parede do XFCE. Agora, ao
 * ligar um monitor (e ao iniciar a sessão), cada tela ligada sem configuração própria recebe a da tela
 * principal: imagem, estilo e cor, em todas as áreas de trabalho.
 *
 *   gcc -O2 -o codeos-wallpaper-sync codeos-wallpaper-sync.c \
 *       $(pkg-config --cflags --libs libxfconf-0 xrandr x11)
 */
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <xfconf/xfconf.h>
#include <string.h>

#define CANAL "xfce4-desktop"
#define CHAVE "/codeos/all-displays"

/* o que define a imagem de uma tela; a cor de fundo fica como estiver em cada uma */
static GRegex *chave_imagem;
static XfconfChannel *canal;
static Display *tela_x;
static int evento_randr;
static guint completar_pendente;

static gboolean
eh_texto (const gchar *prop)
{
    return g_str_has_suffix (prop, "/last-image");
}

static gchar *
campo (const gchar *prop)
{
    GMatchInfo *m = NULL;
    gchar *res = NULL;
    if (g_regex_match (chave_imagem, prop, 0, &m))
        res = g_match_info_fetch (m, 1);
    g_match_info_free (m);
    return res;
}

static gboolean
iguais (XfconfChannel *ch, const gchar *a, const gchar *b)
{
    if (eh_texto (a)) {
        gchar *x = xfconf_channel_get_string (ch, a, ""), *y = xfconf_channel_get_string (ch, b, "");
        gboolean r = g_strcmp0 (x, y) == 0;
        g_free (x);
        g_free (y);
        return r;
    }
    return xfconf_channel_get_int (ch, a, 0) == xfconf_channel_get_int (ch, b, 0);
}

/* copia o valor de uma tela para a mesma chave de todas as telas e áreas de trabalho */
static void
espelhar (XfconfChannel *ch, const gchar *origem)
{
    gchar *qual = campo (origem);
    GHashTable *props = xfconf_channel_get_properties (ch, "/backdrop");
    GHashTableIter it;
    gpointer chave;

    if (qual == NULL || props == NULL) {
        g_free (qual);
        if (props != NULL)
            g_hash_table_destroy (props);
        return;
    }
    g_hash_table_iter_init (&it, props);
    while (g_hash_table_iter_next (&it, &chave, NULL)) {
        gchar *outro = campo (chave);
        if (outro != NULL && strcmp (outro, qual) == 0 && strcmp (chave, origem) != 0
            && !iguais (ch, chave, origem)) {
            if (eh_texto (origem)) {
                gchar *v = xfconf_channel_get_string (ch, origem, "");
                xfconf_channel_set_string (ch, chave, v);
                g_free (v);
            } else {
                xfconf_channel_set_int (ch, chave, xfconf_channel_get_int (ch, origem, 0));
            }
        }
        g_free (outro);
    }
    g_hash_table_destroy (props);
    g_free (qual);
}

/* "monitorHDMI-1/" da tela principal */
static gchar *
principal (void)
{
    gchar *res = g_strdup ("monitor");
    if (tela_x != NULL) {
        Window raiz = DefaultRootWindow (tela_x);
        RROutput saida = XRRGetOutputPrimary (tela_x, raiz);
        XRRScreenResources *rec = XRRGetScreenResourcesCurrent (tela_x, raiz);
        if (saida != None && rec != NULL) {
            XRROutputInfo *info = XRRGetOutputInfo (tela_x, rec, saida);
            if (info != NULL) {
                g_free (res);
                res = g_strdup_printf ("monitor%s/", info->name);
                XRRFreeOutputInfo (info);
            }
        }
        if (rec != NULL)
            XRRFreeScreenResources (rec);
    }
    return res;
}

/* nomes das saídas ligadas e em uso (com imagem) */
static GPtrArray *
saidas_ligadas (void)
{
    GPtrArray *nomes = g_ptr_array_new_with_free_func (g_free);
    XRRScreenResources *rec;
    if (tela_x == NULL)
        return nomes;
    rec = XRRGetScreenResourcesCurrent (tela_x, DefaultRootWindow (tela_x));
    if (rec == NULL)
        return nomes;
    for (int i = 0; i < rec->noutput; i++) {
        XRROutputInfo *info = XRRGetOutputInfo (tela_x, rec, rec->outputs[i]);
        if (info == NULL)
            continue;
        if (info->connection == RR_Connected && info->crtc != None)
            g_ptr_array_add (nomes, g_strdup (info->name));
        XRRFreeOutputInfo (info);
    }
    XRRFreeScreenResources (rec);
    return nomes;
}

static gboolean
tem_prefixo (GHashTable *props, const gchar *prefixo)
{
    GHashTableIter it;
    gpointer chave;
    g_hash_table_iter_init (&it, props);
    while (g_hash_table_iter_next (&it, &chave, NULL))
        if (g_str_has_prefix (chave, prefixo))
            return TRUE;
    return FALSE;
}

/* cada tela ligada sem configuração própria recebe a da tela principal (ou da primeira já configurada) */
static gboolean
completar_telas (gpointer dados)
{
    GHashTable *props = xfconf_channel_get_properties (canal, "/backdrop");
    GPtrArray *ligadas = saidas_ligadas ();
    gchar *origem = NULL;

    completar_pendente = 0;
    if (props != NULL && ligadas->len > 0) {
        gchar *p = principal ();
        gchar *chave = g_strdup_printf ("/backdrop/screen0/%sworkspace0/last-image", p);
        if (g_hash_table_contains (props, chave))
            origem = g_strdup_printf ("/backdrop/screen0/%s", p);
        g_free (chave);
        g_free (p);
        for (guint i = 0; origem == NULL && i < ligadas->len; i++) {
            chave = g_strdup_printf ("/backdrop/screen0/monitor%s/workspace0/last-image",
                                     (gchar *) g_ptr_array_index (ligadas, i));
            if (g_hash_table_contains (props, chave))
                origem = g_strdup_printf ("/backdrop/screen0/monitor%s/",
                                          (gchar *) g_ptr_array_index (ligadas, i));
            g_free (chave);
        }
    }
    for (guint i = 0; origem != NULL && i < ligadas->len; i++) {
        gchar *destino = g_strdup_printf ("/backdrop/screen0/monitor%s/",
                                          (gchar *) g_ptr_array_index (ligadas, i));
        if (!tem_prefixo (props, destino)) {
            GHashTableIter it;
            gpointer chave, valor;
            g_hash_table_iter_init (&it, props);
            while (g_hash_table_iter_next (&it, &chave, &valor))
                if (g_str_has_prefix (chave, origem)) {
                    gchar *nova = g_strconcat (destino, (gchar *) chave + strlen (origem), NULL);
                    xfconf_channel_set_property (canal, nova, valor);
                    g_free (nova);
                }
        }
        g_free (destino);
    }
    g_free (origem);
    g_ptr_array_unref (ligadas);
    if (props != NULL)
        g_hash_table_destroy (props);
    return G_SOURCE_REMOVE;
}

/* monitor ligado, desligado ou trocado: espera o xrandr e o xfdesktop assentarem e completa as telas */
static gboolean
evento_x (GIOChannel *fonte, GIOCondition cond, gpointer dados)
{
    gboolean mudou_saida = FALSE;
    while (XPending (tela_x)) {
        XEvent ev;
        XNextEvent (tela_x, &ev);
        if (ev.type == evento_randr + RRScreenChangeNotify || ev.type == evento_randr + RRNotify) {
            XRRUpdateConfiguration (&ev);
            mudou_saida = TRUE;
        }
    }
    if (mudou_saida) {
        if (completar_pendente != 0)
            g_source_remove (completar_pendente);
        completar_pendente = g_timeout_add (1500, completar_telas, NULL);
    }
    return G_SOURCE_CONTINUE;
}

static void
mudou (XfconfChannel *ch, const gchar *prop, const GValue *valor, gpointer dados)
{
    if (!xfconf_channel_get_bool (ch, CHAVE, TRUE))
        return;
    if (g_regex_match (chave_imagem, prop, 0, NULL)) {
        /* as cópias também disparam este sinal, mas já chegam iguais e não são copiadas de novo */
        espelhar (ch, prop);
    } else if (strcmp (prop, CHAVE) == 0) {
        /* ao ligar a chave, todas as telas ficam com o papel de parede da tela principal */
        gchar *tela = principal ();
        GHashTable *props = xfconf_channel_get_properties (ch, "/backdrop");
        GHashTableIter it;
        gpointer chave;
        if (props != NULL) {
            g_hash_table_iter_init (&it, props);
            while (g_hash_table_iter_next (&it, &chave, NULL))
                if (g_regex_match (chave_imagem, chave, 0, NULL) && strstr (chave, "/workspace0/") != NULL
                    && strstr (chave, tela) != NULL)
                    espelhar (ch, chave);
            g_hash_table_destroy (props);
        }
        g_free (tela);
    }
}

int
main (void)
{
    GError *erro = NULL;
    int erro_randr;

    if (!xfconf_init (&erro)) {
        g_printerr ("xfconf: %s\n", erro->message);
        return 1;
    }
    chave_imagem = g_regex_new ("^/backdrop/screen\\d+/monitor[^/]+/workspace\\d+/(last-image|image-style)$",
                                0, 0, NULL);
    canal = xfconf_channel_new (CANAL);
    g_signal_connect (canal, "property-changed", G_CALLBACK (mudou), NULL);

    tela_x = XOpenDisplay (NULL);
    if (tela_x != NULL && XRRQueryExtension (tela_x, &evento_randr, &erro_randr)) {
        XRRSelectInput (tela_x, DefaultRootWindow (tela_x), RRScreenChangeNotifyMask | RROutputChangeNotifyMask);
        g_io_add_watch (g_io_channel_unix_new (ConnectionNumber (tela_x)), G_IO_IN, evento_x, NULL);
        completar_telas (NULL);
    }
    g_main_loop_run (g_main_loop_new (NULL, FALSE));
    return 0;
}
