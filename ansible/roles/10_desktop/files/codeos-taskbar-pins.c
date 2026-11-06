/*
 * Módulo do CodeOS para a barra de tarefas: programas fixados, como no Windows.
 *
 * Não é um item da barra: é um módulo GTK que o /usr/local/bin/xfce4-panel carrega (GTK_MODULES) dentro
 * do xfce4-panel. Ele:
 *   - acrescenta "Pin to taskbar" / "Unpin from taskbar" no menu de um programa aberto na lista de janelas;
 *   - desenha os programas fixados logo antes da lista de janelas de cada barra (clique abre; botão direito
 *     tem o programa e "Unpin from taskbar");
 *   - esconde o ícone fixado enquanto o programa tem janela naquela tela, para ele não aparecer duas vezes
 *     (o botão da janela toma o lugar dele).
 * Também é carregado na bandeja, que roda fora da barra: o wrapper-2.0 do xfce4-panel é desviado com
 * dpkg-divert para wrapper-2.0.real e no lugar dele fica um script que carrega este módulo. Ali ele dá aos
 * ícones antigos da bandeja o espaço de 24 px dos novos; o volume e as notificações, que rodam dentro da
 * barra, ficam com ícone de 16 px num espaço de 24 px.
 * Os botões das janelas abertas usam o ícone do tema, do mesmo tamanho dos fixados, e mostram a prévia
 * das janelas ao passar o mouse (ver "prévia das janelas").
 * A barra só aparece quando está completa, com todos os plugins e ícones (ver "a barra aparece inteira").
 * Fixar e desafixar mudam só os ícones, na hora, sem recarregar a barra. A lista fica em
 * ~/.config/codeos/taskbar-pins (um .desktop por linha); sem ela vale a do sistema
 * (/etc/xdg/xdg-codeos/codeos/taskbar-pins), então continua depois de reiniciar.
 *
 *   gcc -shared -fPIC -O2 -o libcodeos-taskbar-pins.so codeos-taskbar-pins.c \
 *       $(pkg-config --cflags --libs libwnck-3.0 gio-unix-2.0 x11 xcomposite cairo-xlib)
 */
#define WNCK_I_KNOW_THIS_IS_UNSTABLE
#include <gio/gdesktopappinfo.h>
#include <X11/Xatom.h>
#include <gdk/gdkx.h>
#include <cairo-xlib.h>
#include <X11/extensions/Xcomposite.h>
#include <gtk/gtkx.h>
#include <libwnck/libwnck.h>
#include <locale.h>
#include <string.h>

#define MARCA   "codeos-pin-item"
#define CAIXA   "codeos-pins-box"
#define ARQUIVO "codeos/taskbar-pins"

static gboolean   montado = FALSE;   /* ícones fixados já postos na barra */
static GPtrArray *fixos = NULL;      /* caminhos dos .desktop fixados, na ordem da barra */
static GList     *programas = NULL;  /* GAppInfo de todos os programas */
static guint      recalculo = 0;

static void reconstruir (void);
static void agendar (void);
static void iniciar_previas (void);

/* ── textos ─────────────────────────────────────────────────────────────────────────────────── */

static gboolean
portugues (void)
{
    const gchar *idioma = setlocale (LC_MESSAGES, NULL);
    return idioma != NULL && g_str_has_prefix (idioma, "pt");
}

#define TXT_FIXAR     (portugues () ? "Fixar na barra de tarefas" : "Pin to taskbar")
#define TXT_DESAFIXAR (portugues () ? "Desafixar da barra de tarefas" : "Unpin from taskbar")

/* ── lista de fixados ───────────────────────────────────────────────────────────────────────── */

static void
ler_fixos (void)
{
    gchar *usuario = g_build_filename (g_get_user_config_dir (), ARQUIVO, NULL);
    gchar *texto = NULL;

    if (!g_file_get_contents (usuario, &texto, NULL, NULL))
        for (const gchar * const *d = g_get_system_config_dirs (); *d != NULL && texto == NULL; d++) {
            gchar *sistema = g_build_filename (*d, ARQUIVO, NULL);
            g_file_get_contents (sistema, &texto, NULL, NULL);
            g_free (sistema);
        }
    g_ptr_array_set_size (fixos, 0);
    if (texto != NULL) {
        gchar **linhas = g_strsplit (texto, "\n", -1);
        for (gchar **l = linhas; *l != NULL; l++)
            if (**l == '/' && g_file_test (*l, G_FILE_TEST_EXISTS))
                g_ptr_array_add (fixos, g_strdup (*l));
        g_strfreev (linhas);
    }
    g_free (texto);
    g_free (usuario);
}

static void
salvar_fixos (void)
{
    gchar *arquivo = g_build_filename (g_get_user_config_dir (), ARQUIVO, NULL);
    gchar *pasta = g_path_get_dirname (arquivo);
    GString *texto = g_string_new (NULL);

    for (guint i = 0; i < fixos->len; i++)
        g_string_append_printf (texto, "%s\n", (gchar *) g_ptr_array_index (fixos, i));
    g_mkdir_with_parents (pasta, 0755);
    g_file_set_contents (arquivo, texto->str, -1, NULL);
    g_string_free (texto, TRUE);
    g_free (pasta);
    g_free (arquivo);
}

static gint
posicao (const gchar *desktop)
{
    for (guint i = 0; i < fixos->len; i++)
        if (g_strcmp0 (g_ptr_array_index (fixos, i), desktop) == 0)
            return i;
    return -1;
}

static void
fixar (const gchar *desktop)
{
    if (posicao (desktop) < 0)
        g_ptr_array_add (fixos, g_strdup (desktop));
    salvar_fixos ();
    reconstruir ();
}

static void
desafixar (const gchar *desktop)
{
    gint i = posicao (desktop);
    if (i >= 0)
        g_ptr_array_remove_index (fixos, i);
    salvar_fixos ();
    reconstruir ();
}

/* ── programa de uma janela ─────────────────────────────────────────────────────────────────── */

static void
programas_mudaram (GAppInfoMonitor *monitor, gpointer dados)
{
    g_list_free_full (programas, g_object_unref);
    programas = NULL;
}

static gboolean
igual (const gchar *a, const gchar *b)
{
    return a != NULL && b != NULL && *a != '\0' && g_ascii_strcasecmp (a, b) == 0;
}

static gchar *
executavel (GAppInfo *app)
{
    const gchar *exec = g_app_info_get_executable (app);
    return exec != NULL ? g_path_get_basename (exec) : NULL;
}

/* caminho do .desktop do programa da janela, ou NULL */
static const gchar *
programa_da_janela (WnckWindow *janela)
{
    const gchar *classe = wnck_window_get_class_group_name (janela);
    const gchar *instancia = wnck_window_get_class_instance_name (janela);
    gchar *exe = NULL;
    const gchar *achado = NULL;
    gint nivel_achado = 99;

    if (programas == NULL)
        programas = g_app_info_get_all ();

    if (wnck_window_get_pid (janela) > 0) {
        gchar *link = g_strdup_printf ("/proc/%d/exe", wnck_window_get_pid (janela));
        gchar *alvo = g_file_read_link (link, NULL);
        if (alvo != NULL)
            exe = g_path_get_basename (alvo);
        g_free (alvo);
        g_free (link);
    }

    for (GList *l = programas; l != NULL; l = l->next) {
        GDesktopAppInfo *app = G_DESKTOP_APP_INFO (l->data);
        const gchar *wm = g_desktop_app_info_get_startup_wm_class (app);
        const gchar *id = g_app_info_get_id (G_APP_INFO (app));
        gchar *nome = id != NULL ? g_strndup (id, strlen (id) - (g_str_has_suffix (id, ".desktop") ? 8 : 0)) : NULL;
        const gchar *ponto = nome != NULL ? strrchr (nome, '.') : NULL;
        gchar *prog = executavel (G_APP_INFO (app));
        gint nivel = 99;

        if (igual (wm, classe) || igual (wm, instancia))
            nivel = 0;
        else if (igual (nome, instancia) || igual (nome, classe))
            nivel = 1;
        else if (ponto != NULL && (igual (ponto + 1, instancia) || igual (ponto + 1, classe)))
            nivel = 2;
        else if (igual (prog, instancia) || igual (prog, classe))
            nivel = 3;
        else if (igual (prog, exe))
            nivel = 4;
        if (nivel < 99 && !g_app_info_should_show (G_APP_INFO (app)))
            nivel += 10;  /* prefere os programas que aparecem no menu */
        if (nivel < nivel_achado) {
            nivel_achado = nivel;
            achado = g_desktop_app_info_get_filename (app);
        }
        g_free (nome);
        g_free (prog);
    }
    g_free (exe);
    return achado;
}

/* ── ícones fixados ─────────────────────────────────────────────────────────────────────────── */

static void
procurar_listas (GtkWidget *w, gpointer lista)
{
    if (g_strcmp0 (G_OBJECT_TYPE_NAME (w), "XfceTasklist") == 0)
        *(GList **) lista = g_list_prepend (*(GList **) lista, w);
    else if (GTK_IS_CONTAINER (w))
        gtk_container_forall (GTK_CONTAINER (w), procurar_listas, lista);
}

static gboolean
reconstruir_depois (gpointer dados)
{
    reconstruir ();
    return G_SOURCE_REMOVE;
}

/* os botões fixados são quadrados da altura da barra: no boot eles nascem antes de a barra ter altura,
 * então são refeitos quando a altura da lista de janelas muda */
static void
lista_alocada (GtkWidget *lista, GtkAllocation *area)
{
    gint antes = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (lista), "codeos-altura"));

    if (area->height != antes) {
        g_object_set_data (G_OBJECT (lista), "codeos-altura", GINT_TO_POINTER (area->height));
        g_idle_add (reconstruir_depois, NULL);
    }
}

/* a caixa de ícones fixados ao lado de cada lista de janelas (criada na primeira vez) */
static GList *
caixas (void)
{
    GList *listas = NULL, *res = NULL, *janelas = gtk_window_list_toplevels ();

    for (GList *l = janelas; l != NULL; l = l->next)
        if (g_strcmp0 (G_OBJECT_TYPE_NAME (l->data), "XfcePanelWindow") == 0)
            procurar_listas (l->data, &listas);
    g_list_free (janelas);

    for (GList *l = listas; l != NULL; l = l->next) {
        GtkWidget *lista = l->data, *pai = gtk_widget_get_parent (lista);
        GtkWidget *caixa = g_object_get_data (G_OBJECT (lista), CAIXA);

        if (caixa == NULL && GTK_IS_BOX (pai)) {
            gint i = 0;
            GList *filhos = gtk_container_get_children (GTK_CONTAINER (pai));
            i = g_list_index (filhos, lista);
            g_list_free (filhos);
            caixa = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_box_pack_start (GTK_BOX (pai), caixa, FALSE, FALSE, 0);
            gtk_box_reorder_child (GTK_BOX (pai), caixa, i);
            gtk_widget_show (caixa);
            g_object_set_data (G_OBJECT (caixa), "lista", lista);
            g_object_set_data (G_OBJECT (lista), CAIXA, caixa);
            g_object_set_data (G_OBJECT (lista), "codeos-altura",
                               GINT_TO_POINTER (gtk_widget_get_allocated_height (lista)));
            g_signal_connect (lista, "size-allocate", G_CALLBACK (lista_alocada), NULL);
        }
        if (caixa != NULL)
            res = g_list_prepend (res, caixa);
    }
    g_list_free (listas);
    return res;
}

static void
abrir (const gchar *desktop, GtkWidget *origem)
{
    GDesktopAppInfo *app = g_desktop_app_info_new_from_filename (desktop);
    GdkAppLaunchContext *ctx = gdk_display_get_app_launch_context (gtk_widget_get_display (origem));

    gdk_app_launch_context_set_timestamp (ctx, gtk_get_current_event_time ());
    if (app != NULL)
        g_app_info_launch (G_APP_INFO (app), NULL, G_APP_LAUNCH_CONTEXT (ctx), NULL);
    g_object_unref (ctx);
    g_clear_object (&app);
}

static void
item_abrir (GtkMenuItem *item, gpointer botao)
{
    abrir (g_object_get_data (botao, "desktop"), botao);
}

static void
item_desafixar (GtkMenuItem *item, gpointer desktop)
{
    desafixar (desktop);
}

static gboolean
clique (GtkWidget *botao, GdkEventButton *ev, gpointer dados)
{
    const gchar *desktop = g_object_get_data (G_OBJECT (botao), "desktop");
    GtkWidget *menu, *item;

    if (ev->type != GDK_BUTTON_RELEASE)
        return ev->button == 3;  /* o direito abre o menu ao soltar, como a lista de janelas */
    if (ev->button == 1 || ev->button == 2) {
        abrir (desktop, botao);
        return FALSE;
    }
    if (ev->button != 3)
        return FALSE;

    menu = gtk_menu_new ();
    item = gtk_menu_item_new_with_label (gtk_widget_get_tooltip_text (botao));
    g_signal_connect (item, "activate", G_CALLBACK (item_abrir), botao);
    gtk_menu_shell_append (GTK_MENU_SHELL (menu), item);
    gtk_menu_shell_append (GTK_MENU_SHELL (menu), gtk_separator_menu_item_new ());
    item = gtk_menu_item_new_with_label (TXT_DESAFIXAR);
    g_signal_connect_data (item, "activate", G_CALLBACK (item_desafixar), g_strdup (desktop),
                           (GClosureNotify) (void (*) (void)) g_free, 0);
    gtk_menu_shell_append (GTK_MENU_SHELL (menu), item);
    gtk_widget_show_all (menu);
    gtk_menu_attach_to_widget (GTK_MENU (menu), botao, NULL);
    /* selection-done vem depois do "activate" do item (o deactivate viria antes e mataria o item) */
    g_signal_connect (menu, "selection-done", G_CALLBACK (gtk_widget_destroy), NULL);
    gtk_menu_popup_at_widget (GTK_MENU (menu), botao, GDK_GRAVITY_NORTH_WEST, GDK_GRAVITY_SOUTH_WEST, (GdkEvent *) ev);
    return TRUE;
}

/* tamanho único dos ícones da barra (fixados e janelas abertas), como no Windows: 24 px sempre, sem
 * depender da altura da barra (no boot os fixados nasciam antes de ela ter tamanho e ficavam com 16 px) */
#define ICONE_BARRA 24

static void
reconstruir (void)
{
    GList *lista = caixas ();

    for (GList *l = lista; l != NULL; l = l->next) {
        GtkWidget *caixa = l->data, *janelas = g_object_get_data (G_OBJECT (caixa), "lista");
        gint altura = gtk_widget_get_allocated_height (janelas);
        GList *velhos = gtk_container_get_children (GTK_CONTAINER (caixa));

        g_list_free_full (velhos, (GDestroyNotify) gtk_widget_destroy);

        for (guint i = 0; i < fixos->len; i++) {
            const gchar *desktop = g_ptr_array_index (fixos, i);
            GDesktopAppInfo *app = g_desktop_app_info_new_from_filename (desktop);
            GtkWidget *botao, *imagem;

            if (app == NULL)
                continue;
            botao = gtk_button_new ();
            gtk_button_set_relief (GTK_BUTTON (botao), GTK_RELIEF_NONE);
            gtk_widget_set_focus_on_click (botao, FALSE);
            gtk_widget_set_tooltip_text (botao, g_app_info_get_name (G_APP_INFO (app)));
            imagem = gtk_image_new_from_gicon (g_app_info_get_icon (G_APP_INFO (app)), GTK_ICON_SIZE_BUTTON);
            gtk_image_set_pixel_size (GTK_IMAGE (imagem), ICONE_BARRA);
            gtk_container_add (GTK_CONTAINER (botao), imagem);
            if (altura > 0)
                gtk_widget_set_size_request (botao, altura, altura);
            g_object_set_data_full (G_OBJECT (botao), "desktop", g_strdup (desktop), g_free);
            g_signal_connect (botao, "button-press-event", G_CALLBACK (clique), NULL);
            g_signal_connect (botao, "button-release-event", G_CALLBACK (clique), NULL);
            gtk_widget_show_all (botao);
            gtk_box_pack_start (GTK_BOX (caixa), botao, FALSE, FALSE, 0);
            g_object_unref (app);
        }
    }
    g_list_free (lista);
    agendar ();
}

static GdkMonitor *
monitor_do_widget (GtkWidget *w)
{
    GdkWindow *gw = gtk_widget_get_window (gtk_widget_get_toplevel (w));
    return gw != NULL ? gdk_display_get_monitor_at_window (gdk_display_get_default (), gw) : NULL;
}

/* esconde o ícone fixado enquanto o programa tem janela na tela daquela barra */
static gboolean
recalcular (gpointer dados)
{
    GdkDisplay *tela = gdk_display_get_default ();
    WnckScreen *screen = wnck_screen_get_default ();
    GList *lista = caixas ();

    recalculo = 0;
    for (GList *l = lista; l != NULL; l = l->next) {
        GdkMonitor *monitor = monitor_do_widget (l->data);
        gint escala = monitor != NULL ? gdk_monitor_get_scale_factor (monitor) : 1;
        GHashTable *abertos = g_hash_table_new (g_str_hash, g_str_equal);
        GList *botoes = gtk_container_get_children (GTK_CONTAINER (l->data));

        for (GList *j = wnck_screen_get_windows (screen); j != NULL; j = j->next) {
            WnckWindow *janela = j->data;
            const gchar *desktop;
            gint x, y, lar, alt;
            if (wnck_window_is_skip_tasklist (janela))
                continue;
            wnck_window_get_geometry (janela, &x, &y, &lar, &alt);
            if (monitor != NULL &&
                gdk_display_get_monitor_at_point (tela, (x + lar / 2) / escala, (y + alt / 2) / escala) != monitor)
                continue;
            desktop = programa_da_janela (janela);
            if (desktop != NULL)
                g_hash_table_add (abertos, (gpointer) desktop);
        }
        for (GList *b = botoes; b != NULL; b = b->next)
            gtk_widget_set_visible (b->data, !g_hash_table_contains (abertos, g_object_get_data (b->data, "desktop")));
        g_list_free (botoes);
        g_hash_table_unref (abertos);
    }
    g_list_free (lista);
    return G_SOURCE_REMOVE;
}

static void
agendar (void)
{
    if (recalculo == 0)
        recalculo = g_timeout_add (250, recalcular, NULL);
}

static void janela_mudou (WnckWindow *janela, gpointer dados) { agendar (); }

static void
janela_abriu (WnckScreen *screen, WnckWindow *janela, gpointer dados)
{
    g_signal_connect (janela, "geometry-changed", G_CALLBACK (janela_mudou), NULL);
    g_signal_connect (janela, "class-changed", G_CALLBACK (janela_mudou), NULL);
    agendar ();
}

static void janela_fechou (WnckScreen *screen, WnckWindow *janela, gpointer dados) { agendar (); }

/* ── menu da lista de janelas ───────────────────────────────────────────────────────────────── */

static void
executar (GtkMenuItem *item, gpointer desktop)
{
    if (posicao (desktop) >= 0)
        desafixar (desktop);
    else
        fixar (desktop);
}

static void
acrescentar (GtkMenu *menu, const gchar *desktop)
{
    GtkWidget *item = gtk_menu_item_new_with_label (posicao (desktop) >= 0 ? TXT_DESAFIXAR : TXT_FIXAR);
    GtkWidget *separador = gtk_separator_menu_item_new ();

    g_signal_connect_data (item, "activate", G_CALLBACK (executar), g_strdup (desktop),
                           (GClosureNotify) (void (*) (void)) g_free, 0);
    gtk_menu_shell_prepend (GTK_MENU_SHELL (menu), separador);
    gtk_menu_shell_prepend (GTK_MENU_SHELL (menu), item);
    gtk_widget_show (item);
    gtk_widget_show (separador);
    g_object_set_data (G_OBJECT (menu), MARCA, item);
}

/* a janela de um menu da lista de janelas: o próprio menu de ações, ou o menu de um grupo (cada item
   tem um submenu de ações) */
static WnckWindow *
janela_do_menu (GtkMenu *menu)
{
    WnckWindow *janela = NULL;
    GList *itens;

    if (WNCK_IS_ACTION_MENU (menu)) {
        g_object_get (menu, "window", &janela, NULL);
        return janela;
    }
    itens = gtk_container_get_children (GTK_CONTAINER (menu));
    for (GList *l = itens; l != NULL && janela == NULL; l = l->next)
        if (GTK_IS_MENU_ITEM (l->data)) {
            GtkWidget *sub = gtk_menu_item_get_submenu (l->data);
            if (sub != NULL && WNCK_IS_ACTION_MENU (sub))
                g_object_get (sub, "window", &janela, NULL);
        }
    g_list_free (itens);
    return janela;
}

/* todo menu passa por aqui ao aparecer (antes de ser medido); só os da lista de janelas interessam */
static gboolean
ao_mostrar (GSignalInvocationHint *dica, guint n, const GValue *params, gpointer dados)
{
    GObject *obj = g_value_get_object (&params[0]);
    GtkWidget *dono;
    WnckWindow *janela;
    const gchar *desktop;

    if (!GTK_IS_MENU (obj) || g_object_get_data (obj, MARCA) != NULL)
        return TRUE;
    dono = gtk_menu_get_attach_widget (GTK_MENU (obj));
    if (dono == NULL || GTK_IS_MENU_ITEM (dono) ||
        gtk_widget_get_ancestor (dono, g_type_from_name ("XfceTasklist")) == NULL)
        return TRUE;  /* submenu, ou menu de outra coisa */

    janela = janela_do_menu (GTK_MENU (obj));
    desktop = janela != NULL ? programa_da_janela (janela) : NULL;
    if (desktop != NULL)
        acrescentar (GTK_MENU (obj), desktop);
    return TRUE;
}

/* ── módulo ─────────────────────────────────────────────────────────────────────────────────── */

static gboolean
montar (gpointer dados)
{
    reconstruir ();
    montado = TRUE;
    return G_SOURCE_REMOVE;
}

static gboolean
iniciar (gpointer dados)
{
    WnckScreen *screen = wnck_screen_get_default ();

    fixos = g_ptr_array_new_with_free_func (g_free);
    ler_fixos ();
    g_signal_connect (g_app_info_monitor_get (), "changed", G_CALLBACK (programas_mudaram), NULL);
    g_signal_add_emission_hook (g_signal_lookup ("show", GTK_TYPE_WIDGET), 0, ao_mostrar, NULL, NULL);

    wnck_screen_force_update (screen);
    iniciar_previas ();
    for (GList *j = wnck_screen_get_windows (screen); j != NULL; j = j->next)
        janela_abriu (screen, j->data, NULL);
    g_signal_connect (screen, "window-opened", G_CALLBACK (janela_abriu), NULL);
    g_signal_connect (screen, "window-closed", G_CALLBACK (janela_fechou), NULL);
    /* as barras ainda estão se montando: põe os ícones quando já tiverem tamanho */
    g_timeout_add (1500, montar, NULL);
    return G_SOURCE_REMOVE;
}

/* ── ícones das janelas abertas iguais aos fixados ───────────────────────────────────────────── */

/* A lista de janelas desenha o ícone que o próprio programa manda, em 32 px: o do Firefox enche o espaço
 * todo e os do tema têm margem, então o ícone "crescia" ao abrir o programa e "diminuía" ao fechar (quando
 * volta o fixado). Aqui o botão da janela usa o ícone do tema do programa, no tamanho dos fixados. */

static void
achar_rotulo (GtkWidget *w, gpointer texto)
{
    if (*(gchar **) texto != NULL)
        return;
    if (GTK_IS_LABEL (w) && *gtk_label_get_text (GTK_LABEL (w)) != '\0')
        *(gchar **) texto = g_strdup (gtk_label_get_text (GTK_LABEL (w)));
    else if (GTK_IS_CONTAINER (w))
        gtk_container_forall (GTK_CONTAINER (w), achar_rotulo, texto);
}

/* a janela de um botão da lista: a dica do botão é o título da janela (entre [ ] se minimizada); um
 * grupo não tem dica, e o nome (escondido) é o do programa */
static WnckWindow *
janela_do_botao (GtkWidget *botao)
{
    gchar *dica = gtk_widget_get_tooltip_text (botao);
    WnckWindow *achada = NULL;
    gsize n;

    if (dica == NULL)
        achar_rotulo (botao, &dica);
    if (dica == NULL)
        return NULL;
    n = strlen (dica);
    if (n > 2 && dica[0] == '[' && dica[n - 1] == ']') {
        memmove (dica, dica + 1, n - 2);
        dica[n - 2] = '\0';
    }
    for (GList *l = wnck_screen_get_windows (wnck_screen_get_default ()); l != NULL && achada == NULL; l = l->next)
        if (g_strcmp0 (wnck_window_get_name (l->data), dica) == 0)
            achada = l->data;
    for (GList *l = wnck_screen_get_windows (wnck_screen_get_default ()); l != NULL && achada == NULL; l = l->next) {
        WnckClassGroup *grupo = wnck_window_get_class_group (l->data);
        if (grupo != NULL && g_strcmp0 (wnck_class_group_get_name (grupo), dica) == 0)
            achada = l->data;
    }
    g_free (dica);
    return achada;
}

static gboolean
trocar_icone (gpointer dados)
{
    GtkImage *imagem = dados;
    GtkWidget *botao = gtk_widget_get_ancestor (GTK_WIDGET (imagem), GTK_TYPE_BUTTON);
    const gint tamanho = ICONE_BARRA;
    WnckWindow *janela;
    const gchar *desktop;
    GDesktopAppInfo *app = NULL;

    if (botao == NULL || gtk_widget_get_parent (GTK_WIDGET (imagem)) == NULL)
        goto fim;
    janela = janela_do_botao (botao);
    if (janela == NULL) {
        /* botão recém-criado: a dica (título) chega logo depois; tenta de novo por até 3 s */
        gint vezes = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (imagem), "codeos-tentativas"));
        g_object_set_data (G_OBJECT (imagem), "codeos-tentativas", GINT_TO_POINTER (vezes + 1));
        if (vezes < 10) {
            g_timeout_add (300, trocar_icone, imagem);
            return G_SOURCE_REMOVE;  /* a referência segue com a nova tentativa */
        }
    }
    desktop = janela != NULL ? programa_da_janela (janela) : NULL;
    if (desktop != NULL)
        app = g_desktop_app_info_new_from_filename (desktop);
    if (app != NULL && g_app_info_get_icon (G_APP_INFO (app)) != NULL) {
        gtk_image_set_from_gicon (imagem, g_app_info_get_icon (G_APP_INFO (app)), GTK_ICON_SIZE_BUTTON);
        gtk_image_set_pixel_size (imagem, tamanho);
    } else if (gtk_image_get_storage_type (imagem) == GTK_IMAGE_SURFACE) {
        /* programa sem .desktop: o ícone dele, reduzido ao mesmo tamanho */
        cairo_surface_t *sup = NULL;
        g_object_get (imagem, "surface", &sup, NULL);
        if (sup != NULL) {
            gdouble ex, ey;
            gint esc = gtk_widget_get_scale_factor (GTK_WIDGET (imagem));
            cairo_surface_get_device_scale (sup, &ex, &ey);
            if (cairo_image_surface_get_width (sup) / ex > tamanho) {
                GdkPixbuf *grande = gdk_pixbuf_get_from_surface (sup, 0, 0,
                    cairo_image_surface_get_width (sup), cairo_image_surface_get_height (sup));
                if (grande != NULL) {
                    GdkPixbuf *pequeno = gdk_pixbuf_scale_simple (grande, tamanho * esc, tamanho * esc,
                                                                  GDK_INTERP_HYPER);
                    cairo_surface_t *nova = gdk_cairo_surface_create_from_pixbuf (pequeno, esc, NULL);
                    gtk_image_set_from_surface (imagem, nova);
                    cairo_surface_destroy (nova);
                    g_object_unref (pequeno);
                    g_object_unref (grande);
                }
            }
            cairo_surface_destroy (sup);
        }
    }
    if (app != NULL)
        g_object_unref (app);
fim:
    g_object_set_data (G_OBJECT (imagem), "codeos-troca", NULL);
    g_object_set_data (G_OBJECT (imagem), "codeos-tentativas", NULL);
    g_object_unref (imagem);
    return G_SOURCE_REMOVE;
}

/* a lista trocou o ícone (janela nova, ícone novo, minimizada): troca de novo pelo do tema, logo depois */
static void
icone_da_lista_mudou (GtkImage *imagem)
{
    if (gtk_image_get_storage_type (imagem) != GTK_IMAGE_SURFACE
        || g_object_get_data (G_OBJECT (imagem), "codeos-troca") != NULL)
        return;
    g_object_set_data (G_OBJECT (imagem), "codeos-troca", GINT_TO_POINTER (1));
    g_idle_add (trocar_icone, g_object_ref (imagem));
}

static void
acompanhar_icones (GtkWidget *w, gpointer dados)
{
    if (GTK_IS_IMAGE (w)) {
        if (g_object_get_data (G_OBJECT (w), MARCA) == NULL) {
            g_object_set_data (G_OBJECT (w), MARCA, GINT_TO_POINTER (1));
            g_signal_connect (w, "notify::surface", G_CALLBACK (icone_da_lista_mudou), NULL);
        }
        icone_da_lista_mudou (GTK_IMAGE (w));
    } else if (GTK_IS_CONTAINER (w)) {
        gtk_container_forall (GTK_CONTAINER (w), acompanhar_icones, NULL);
    }
}

/* ── prévia das janelas ao passar o mouse ───────────────────────────────────────────────────── */

/* Como no Windows e no Cinnamon: com o mouse parado num programa aberto, aparece acima dele a imagem ao
 * vivo de cada janela, com o título e um ×; clicar traz a janela para a frente. A imagem vem do
 * compositor pela extensão XComposite (o picom já guarda a de cada janela). Janela minimizada não tem
 * imagem no X: vale a última guardada (cada janela é fotografada quando deixa de ser a ativa). Sem
 * imagem (compositor desligado, jogo em tela cheia), fica o ícone. */
#define PREVIA_ESPERA   400   /* ms com o mouse parado até abrir */
#define PREVIA_FECHAR   250   /* ms depois de sair até fechar */
#define PREVIA_LARGURA  200
#define PREVIA_ALTURA   120

static GtkWidget  *previa = NULL;        /* janela da prévia */
static GtkWidget  *previa_botao = NULL;  /* botão da barra a que ela pertence */
static guint       previa_abrir = 0, previa_fechar = 0, previa_atualizar = 0;
static GHashTable *fotos = NULL;         /* XID → última imagem (cairo_surface_t) */

/* imagem atual de uma janela, reduzida para caber em PREVIA_LARGURA × PREVIA_ALTURA, ou NULL */
static cairo_surface_t *
fotografar (WnckWindow *janela)
{
    GdkDisplay *gd = gdk_display_get_default ();
    Display *d = GDK_DISPLAY_XDISPLAY (gd);
    Window cliente = wnck_window_get_xid (janela), quadro = cliente, raiz, pai, *filhos = NULL;
    unsigned int n;
    XWindowAttributes aq, ac;
    Pixmap mapa;
    int cx = 0, cy = 0;
    Window lixo;
    cairo_surface_t *origem, *foto = NULL;
    gdouble escala;
    gint w, h;

    if (wnck_window_is_minimized (janela))
        return NULL;
    gdk_x11_display_error_trap_push (gd);
    /* o compositor guarda a imagem do quadro (a janela com a borda), filho da raiz */
    while (XQueryTree (d, quadro, &raiz, &pai, &filhos, &n) && pai != raiz && pai != 0) {
        if (filhos)
            XFree (filhos);
        filhos = NULL;
        quadro = pai;
    }
    if (filhos)
        XFree (filhos);
    if (!XGetWindowAttributes (d, quadro, &aq) || !XGetWindowAttributes (d, cliente, &ac)
        || aq.map_state != IsViewable || ac.width < 2 || ac.height < 2) {
        gdk_x11_display_error_trap_pop_ignored (gd);
        return NULL;
    }
    XTranslateCoordinates (d, cliente, quadro, 0, 0, &cx, &cy, &lixo);
    /* janelas GTK com decoração própria têm uma sombra transparente em volta (_GTK_FRAME_EXTENTS) */
    {
        Atom tipo;
        int formato;
        unsigned long qtd, resto;
        unsigned char *dados = NULL;
        if (XGetWindowProperty (d, cliente, XInternAtom (d, "_GTK_FRAME_EXTENTS", False), 0, 4, False,
                                XA_CARDINAL, &tipo, &formato, &qtd, &resto, &dados) == Success
            && dados != NULL && qtd == 4 && formato == 32) {
            long *m = (long *) dados;  /* esquerda, direita, cima, baixo */
            cx += m[0];
            cy += m[2];
            ac.width -= m[0] + m[1];
            ac.height -= m[2] + m[3];
        }
        if (dados != NULL)
            XFree (dados);
    }
    mapa = XCompositeNameWindowPixmap (d, quadro);
    XSync (d, False);
    if (gdk_x11_display_error_trap_pop (gd) != 0 || mapa == None)
        return NULL;

    gdk_x11_display_error_trap_push (gd);
    origem = cairo_xlib_surface_create (d, mapa, aq.visual, aq.width, aq.height);
    /* só a área do programa, sem a barra de título */
    escala = MIN ((gdouble) PREVIA_LARGURA / ac.width, (gdouble) PREVIA_ALTURA / ac.height);
    escala = MIN (escala, 1.0);
    w = MAX (1, (gint) (ac.width * escala));
    h = MAX (1, (gint) (ac.height * escala));
    foto = cairo_image_surface_create (CAIRO_FORMAT_ARGB32, w, h);
    {
        cairo_t *cr = cairo_create (foto);
        cairo_scale (cr, escala, escala);
        cairo_set_source_surface (cr, origem, -cx, -cy);
        cairo_pattern_set_filter (cairo_get_source (cr), CAIRO_FILTER_GOOD);
        cairo_paint (cr);
        cairo_destroy (cr);
    }
    cairo_surface_destroy (origem);
    XFreePixmap (d, mapa);
    XSync (d, False);
    if (gdk_x11_display_error_trap_pop (gd) != 0 || cairo_surface_status (foto) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy (foto);
        return NULL;
    }
    g_hash_table_replace (fotos, GUINT_TO_POINTER (cliente), cairo_surface_reference (foto));
    return foto;
}

/* a imagem para mostrar: a de agora ou, minimizada, a última guardada */
static cairo_surface_t *
foto_da_janela (WnckWindow *janela)
{
    cairo_surface_t *foto = fotografar (janela);
    if (foto == NULL) {
        foto = g_hash_table_lookup (fotos, GUINT_TO_POINTER (wnck_window_get_xid (janela)));
        if (foto != NULL)
            cairo_surface_reference (foto);
    }
    return foto;
}

/* a janela que deixa de ser a ativa ainda está na tela: guarda a imagem dela para quando minimizar */
static void
ativa_mudou (WnckScreen *tela, WnckWindow *anterior, gpointer dados)
{
    if (anterior != NULL && WNCK_IS_WINDOW (anterior)) {
        cairo_surface_t *foto = fotografar (anterior);
        if (foto != NULL)
            cairo_surface_destroy (foto);
    }
}

static void
janela_sumiu (WnckScreen *tela, WnckWindow *janela, gpointer dados)
{
    g_hash_table_remove (fotos, GUINT_TO_POINTER (wnck_window_get_xid (janela)));
}

static gboolean
desenhar_foto (GtkWidget *area, cairo_t *cr, gpointer dados)
{
    cairo_surface_t *foto = g_object_get_data (G_OBJECT (area), "foto");
    gint w = gtk_widget_get_allocated_width (area), h = gtk_widget_get_allocated_height (area);

    if (foto != NULL) {
        gint fw = cairo_image_surface_get_width (foto), fh = cairo_image_surface_get_height (foto);
        cairo_set_source_surface (cr, foto, (w - fw) / 2.0, (h - fh) / 2.0);
        cairo_paint (cr);
    }
    return FALSE;
}

static void fechar_previa (void);

static gboolean
cartao_clicado (GtkWidget *cartao, GdkEventButton *ev, WnckWindow *janela)
{
    if (ev->button == 1)
        wnck_window_activate (janela, ev->time);
    else if (ev->button == 2)
        wnck_window_close (janela, ev->time);
    fechar_previa ();
    return TRUE;
}

static void
fechar_janela (GtkButton *x, WnckWindow *janela)
{
    wnck_window_close (janela, gtk_get_current_event_time ());
    fechar_previa ();
}

/* janelas do botão: a dele ou, num grupo, todas as do programa nesta tela */
static GList *
janelas_do_botao (GtkWidget *botao)
{
    WnckWindow *uma = janela_do_botao (botao);
    GdkMonitor *monitor;
    GList *res = NULL;
    gchar *dica;

    if (uma == NULL)
        return NULL;
    dica = gtk_widget_get_tooltip_text (botao);
    if (dica != NULL) {  /* botão de uma janela só */
        g_free (dica);
        return g_list_append (NULL, uma);
    }
    monitor = gdk_display_get_monitor_at_window (gdk_display_get_default (), gtk_widget_get_window (botao));
    for (GList *l = wnck_screen_get_windows (wnck_screen_get_default ()); l != NULL; l = l->next) {
        WnckWindow *j = l->data;
        gint x, y, w, h;
        if (wnck_window_get_class_group (j) != wnck_window_get_class_group (uma) || wnck_window_is_skip_tasklist (j))
            continue;
        wnck_window_get_geometry (j, &x, &y, &w, &h);
        if (gdk_display_get_monitor_at_point (gdk_display_get_default (), x + w / 2, y + h / 2) == monitor)
            res = g_list_append (res, j);
    }
    return res;
}

static gboolean
atualizar_previa (gpointer dados)
{
    if (previa == NULL)
        return G_SOURCE_REMOVE;
    GList *cartoes = gtk_container_get_children (GTK_CONTAINER (gtk_bin_get_child (GTK_BIN (previa))));
    for (GList *l = cartoes; l != NULL; l = l->next) {
        GtkWidget *area = g_object_get_data (G_OBJECT (l->data), "area");
        WnckWindow *janela = g_object_get_data (G_OBJECT (l->data), "janela");
        cairo_surface_t *foto = janela != NULL ? fotografar (janela) : NULL;
        if (foto != NULL) {
            g_object_set_data_full (G_OBJECT (area), "foto", foto, (GDestroyNotify) cairo_surface_destroy);
            gtk_widget_queue_draw (area);
        }
    }
    g_list_free (cartoes);
    return G_SOURCE_CONTINUE;
}

static void
fechar_previa (void)
{
    if (previa_atualizar != 0)
        g_source_remove (previa_atualizar);
    if (previa_fechar != 0)
        g_source_remove (previa_fechar);
    previa_atualizar = previa_fechar = 0;
    if (previa != NULL)
        gtk_widget_destroy (previa);
    previa = NULL;
    previa_botao = NULL;
}

static gboolean
fechar_depois (gpointer dados)
{
    previa_fechar = 0;
    fechar_previa ();
    return G_SOURCE_REMOVE;
}

static void
agendar_fechar (void)
{
    if (previa_fechar == 0)
        previa_fechar = g_timeout_add (PREVIA_FECHAR, fechar_depois, NULL);
}

static void
cancelar_fechar (void)
{
    if (previa_fechar != 0)
        g_source_remove (previa_fechar);
    previa_fechar = 0;
}

static gboolean
mouse_na_previa (GtkWidget *w, GdkEventCrossing *ev, gpointer entrou)
{
    if (ev->detail == GDK_NOTIFY_INFERIOR)
        return FALSE;
    if (entrou)
        cancelar_fechar ();
    else
        agendar_fechar ();
    return FALSE;
}

/* o cartão sob o mouse fica realçado (:hover no CSS) */
static gboolean
realcar_cartao (GtkWidget *evento, GdkEventCrossing *ev, gpointer entrou)
{
    if (ev->detail == GDK_NOTIFY_INFERIOR)
        return FALSE;
    if (entrou)
        gtk_widget_set_state_flags (evento, GTK_STATE_FLAG_PRELIGHT, FALSE);
    else
        gtk_widget_unset_state_flags (evento, GTK_STATE_FLAG_PRELIGHT);
    return FALSE;
}

static GtkWidget *
cartao (WnckWindow *janela)
{
    GtkWidget *evento = gtk_event_box_new (), *caixa = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
    GtkWidget *topo = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6), *titulo, *x, *area;
    GdkPixbuf *icone = wnck_window_get_mini_icon (janela);
    cairo_surface_t *foto = foto_da_janela (janela);

    gtk_style_context_add_class (gtk_widget_get_style_context (evento), "codeos-previa-cartao");
    if (icone != NULL)
        gtk_box_pack_start (GTK_BOX (topo), gtk_image_new_from_pixbuf (icone), FALSE, FALSE, 0);
    titulo = gtk_label_new (wnck_window_get_name (janela));
    gtk_label_set_ellipsize (GTK_LABEL (titulo), PANGO_ELLIPSIZE_END);
    gtk_label_set_xalign (GTK_LABEL (titulo), 0);
    gtk_label_set_max_width_chars (GTK_LABEL (titulo), 1);
    gtk_box_pack_start (GTK_BOX (topo), titulo, TRUE, TRUE, 0);
    x = gtk_button_new_from_icon_name ("window-close-symbolic", GTK_ICON_SIZE_MENU);
    gtk_button_set_relief (GTK_BUTTON (x), GTK_RELIEF_NONE);
    gtk_widget_set_focus_on_click (x, FALSE);
    gtk_widget_set_tooltip_text (x, portugues () ? "Fechar janela" : "Close window");
    g_signal_connect (x, "clicked", G_CALLBACK (fechar_janela), janela);
    gtk_box_pack_end (GTK_BOX (topo), x, FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (caixa), topo, FALSE, FALSE, 0);

    area = gtk_drawing_area_new ();
    gtk_widget_set_size_request (area, PREVIA_LARGURA, PREVIA_ALTURA);
    if (foto != NULL) {
        g_object_set_data_full (G_OBJECT (area), "foto", foto, (GDestroyNotify) cairo_surface_destroy);
        g_signal_connect (area, "draw", G_CALLBACK (desenhar_foto), NULL);
        gtk_box_pack_start (GTK_BOX (caixa), area, FALSE, FALSE, 0);
    } else {
        /* sem imagem: o ícone do programa no lugar */
        GtkWidget *grande = gtk_image_new_from_pixbuf (wnck_window_get_icon (janela));
        gtk_widget_set_size_request (grande, PREVIA_LARGURA, PREVIA_ALTURA);
        gtk_box_pack_start (GTK_BOX (caixa), grande, FALSE, FALSE, 0);
        g_signal_connect (area, "draw", G_CALLBACK (desenhar_foto), NULL);
        g_object_ref_sink (area);
        g_object_set_data_full (G_OBJECT (evento), "area-sem-foto", area, g_object_unref);
    }
    gtk_container_add (GTK_CONTAINER (evento), caixa);
    g_object_set_data (G_OBJECT (evento), "area", area);
    g_object_set_data (G_OBJECT (evento), "janela", janela);
    g_signal_connect (evento, "button-release-event", G_CALLBACK (cartao_clicado), janela);
    gtk_widget_add_events (evento, GDK_ENTER_NOTIFY_MASK | GDK_LEAVE_NOTIFY_MASK);
    g_signal_connect (evento, "enter-notify-event", G_CALLBACK (realcar_cartao), GINT_TO_POINTER (1));
    g_signal_connect (evento, "leave-notify-event", G_CALLBACK (realcar_cartao), NULL);
    return evento;
}

static void
mostrar_previa (GtkWidget *botao)
{
    GList *janelas = janelas_do_botao (botao), *l;
    GtkWidget *linha;
    GdkRectangle area_monitor;
    gint bx, by, pw, ph, x, y;
    GtkAllocation ab;

    fechar_previa ();
    if (janelas == NULL)
        return;
    previa = gtk_window_new (GTK_WINDOW_POPUP);
    gtk_window_set_type_hint (GTK_WINDOW (previa), GDK_WINDOW_TYPE_HINT_NOTIFICATION);  /* opaca no picom */
    gtk_style_context_add_class (gtk_widget_get_style_context (previa), "codeos-previa");
    linha = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 4);
    for (l = janelas; l != NULL; l = l->next)
        gtk_box_pack_start (GTK_BOX (linha), cartao (l->data), FALSE, FALSE, 0);
    g_list_free (janelas);
    gtk_container_add (GTK_CONTAINER (previa), linha);
    gtk_widget_add_events (previa, GDK_ENTER_NOTIFY_MASK | GDK_LEAVE_NOTIFY_MASK);
    g_signal_connect (previa, "enter-notify-event", G_CALLBACK (mouse_na_previa), GINT_TO_POINTER (1));
    g_signal_connect (previa, "leave-notify-event", G_CALLBACK (mouse_na_previa), NULL);
    gtk_widget_show_all (linha);

    /* acima do botão, centrada nele, sem sair da tela */
    gtk_widget_get_preferred_width (previa, NULL, &pw);
    gtk_widget_get_preferred_height (previa, NULL, &ph);
    gdk_window_get_origin (gtk_widget_get_window (botao), &bx, &by);
    gtk_widget_get_allocation (botao, &ab);
    if (!gtk_widget_get_has_window (botao)) {
        bx += ab.x;
        by += ab.y;
    }
    gdk_monitor_get_geometry (gdk_display_get_monitor_at_window (gdk_display_get_default (),
                                                                  gtk_widget_get_window (botao)), &area_monitor);
    x = CLAMP (bx + ab.width / 2 - pw / 2, area_monitor.x + 4, area_monitor.x + area_monitor.width - pw - 4);
    y = by - ph - 6;
    gtk_window_move (GTK_WINDOW (previa), x, y);
    gtk_widget_show (previa);
    previa_botao = botao;
    previa_atualizar = g_timeout_add (500, atualizar_previa, NULL);
}

static gboolean
abrir_previa (gpointer botao)
{
    previa_abrir = 0;
    mostrar_previa (botao);
    return G_SOURCE_REMOVE;
}

static gboolean
mouse_no_botao (GtkWidget *botao, GdkEventCrossing *ev, gpointer entrou)
{
    if (previa_abrir != 0)
        g_source_remove (previa_abrir);
    previa_abrir = 0;
    if (entrou) {
        cancelar_fechar ();
        /* já aberta para outro botão: troca na hora, como no Windows */
        if (previa != NULL && previa_botao != botao)
            mostrar_previa (botao);
        else if (previa == NULL)
            previa_abrir = g_timeout_add (PREVIA_ESPERA, abrir_previa, botao);
    } else if (previa != NULL) {
        agendar_fechar ();
    }
    return FALSE;
}

static gboolean
botao_apertado (GtkWidget *botao, GdkEventButton *ev, gpointer dados)
{
    if (previa_abrir != 0)
        g_source_remove (previa_abrir);
    previa_abrir = 0;
    fechar_previa ();
    return FALSE;
}

/* a prévia toma o lugar da dica com o título (a lista a liga de novo quando o título muda) */
static gboolean
sem_dica (gpointer botao)
{
    if (gtk_widget_get_has_tooltip (botao))
        gtk_widget_set_has_tooltip (botao, FALSE);
    g_object_unref (botao);
    return G_SOURCE_REMOVE;
}

static void
dica_ligada (GtkWidget *botao)
{
    if (gtk_widget_get_has_tooltip (botao))
        g_idle_add (sem_dica, g_object_ref (botao));
}

static void
acompanhar_botao (GtkWidget *botao)
{
    if (botao == NULL || g_object_get_data (G_OBJECT (botao), "codeos-previa") != NULL)
        return;
    g_object_set_data (G_OBJECT (botao), "codeos-previa", GINT_TO_POINTER (1));
    gtk_widget_add_events (botao, GDK_ENTER_NOTIFY_MASK | GDK_LEAVE_NOTIFY_MASK);
    g_signal_connect (botao, "enter-notify-event", G_CALLBACK (mouse_no_botao), GINT_TO_POINTER (1));
    g_signal_connect (botao, "leave-notify-event", G_CALLBACK (mouse_no_botao), NULL);
    g_signal_connect (botao, "button-press-event", G_CALLBACK (botao_apertado), NULL);
    g_signal_connect (botao, "notify::has-tooltip", G_CALLBACK (dica_ligada), NULL);
    g_signal_connect (botao, "destroy", G_CALLBACK (fechar_previa), NULL);
    dica_ligada (botao);
}

static void
iniciar_previas (void)
{
    WnckScreen *tela = wnck_screen_get_default ();

    fotos = g_hash_table_new_full (g_direct_hash, g_direct_equal, NULL, (GDestroyNotify) cairo_surface_destroy);
    g_signal_connect (tela, "active-window-changed", G_CALLBACK (ativa_mudou), NULL);
    g_signal_connect (tela, "window-closed", G_CALLBACK (janela_sumiu), NULL);
}

static gboolean
acompanhar_depois (gpointer conteudo)
{
    if (gtk_widget_get_ancestor (conteudo, g_type_from_name ("XfceTasklist")) != NULL) {
        acompanhar_icones (conteudo, NULL);
        acompanhar_botao (gtk_widget_get_ancestor (conteudo, GTK_TYPE_BUTTON));
    }
    g_object_unref (conteudo);
    return G_SOURCE_REMOVE;
}

/* botão novo na lista de janelas: a lista o põe em si sem o sinal "add", mas o botão recebe o conteúdo
 * (ícone e nome) com ele; logo depois o botão já está na lista */
static gboolean
ao_acrescentar (GSignalInvocationHint *dica, guint n, const GValue *valores, gpointer dados)
{
    GtkWidget *pai = g_value_get_object (&valores[0]);

    if (g_strcmp0 (G_OBJECT_TYPE_NAME (pai), "XfceArrowButton") == 0)
        g_idle_add (acompanhar_depois, g_object_ref (g_value_get_object (&valores[1])));
    return TRUE;
}

/* ── a barra aparece inteira ─────────────────────────────────────────────────────────────────── */

/* Sem isto a barra aparecia vazia e ia se completando por quase 3 s: o botão iniciar, a bandeja, o volume
 * e o sino rodam em processos à parte e chegam um por um, e cada programa da bandeja põe o seu ícone
 * quando abre. A janela da barra nasce invisível e só aparece quando todos os plugins estão nela e nada
 * mudou de tamanho por ESPERA_QUIETA ms (ou depois de ESPERA_MAXIMA ms, se algo demorar). Precisa do
 * compositor, que a sessão (codeos-session) liga antes da barra. */
#define ESPERA_QUIETA 1600
#define ESPERA_MAXIMA 6000

static gboolean revelada = FALSE;
static guint    quieta = 0;

static gboolean
plugins_prontos (GtkWidget *w)
{
    gboolean prontos = TRUE;

    if (GTK_IS_SOCKET (w))
        return gtk_socket_get_plug_window (GTK_SOCKET (w)) != NULL;
    if (GTK_IS_CONTAINER (w)) {
        GList *filhos = gtk_container_get_children (GTK_CONTAINER (w));
        for (GList *i = filhos; i != NULL && prontos; i = i->next)
            prontos = plugins_prontos (i->data);
        g_list_free (filhos);
    }
    return prontos;
}

/* opacidade direto na janela X (_NET_WM_WINDOW_OPACITY, lida pelo compositor): pelo GTK
 * (gtk_widget_set_opacity) a barra passa a se desenhar de outro jeito e os plugins de fora somem dela */
static void
opacidade_x (GtkWidget *janela, gboolean visivel)
{
    GdkWindow *gw = gtk_widget_get_window (janela);
    Display *d;
    Atom atomo;

    if (gw == NULL || !GDK_IS_X11_WINDOW (gw))
        return;
    d = GDK_WINDOW_XDISPLAY (gw);
    atomo = XInternAtom (d, "_NET_WM_WINDOW_OPACITY", False);
    if (visivel) {
        XDeleteProperty (d, GDK_WINDOW_XID (gw), atomo);
    } else {
        unsigned long zero = 0;
        XChangeProperty (d, GDK_WINDOW_XID (gw), atomo, XA_CARDINAL, 32, PropModeReplace,
                         (unsigned char *) &zero, 1);
    }
}

static void
mostrar_barras (void)
{
    GList *janelas = gtk_window_list_toplevels ();

    for (GList *i = janelas; i != NULL; i = i->next)
        if (g_strcmp0 (G_OBJECT_TYPE_NAME (i->data), "XfcePanelWindow") == 0)
            opacidade_x (i->data, TRUE);
    g_list_free (janelas);
}

static gboolean
revelar (gpointer forcar)
{
    GList *janelas;
    gboolean prontos = montado;

    if (revelada)
        return G_SOURCE_REMOVE;
    janelas = gtk_window_list_toplevels ();
    for (GList *i = janelas; i != NULL && prontos; i = i->next)
        if (g_strcmp0 (G_OBJECT_TYPE_NAME (i->data), "XfcePanelWindow") == 0)
            prontos = plugins_prontos (i->data);
    g_list_free (janelas);
    if (!prontos && forcar == NULL)
        return G_SOURCE_CONTINUE;  /* confere de novo daqui a ESPERA_QUIETA ms */
    revelada = TRUE;
    if (quieta != 0)
        g_source_remove (quieta);
    quieta = 0;
    mostrar_barras ();
    return G_SOURCE_REMOVE;
}

static void
recomecar_espera (void)
{
    if (quieta != 0)
        g_source_remove (quieta);
    quieta = g_timeout_add (ESPERA_QUIETA, revelar, NULL);
}

/* "map" chega com a janela já criada e antes de ela aparecer */
static gboolean
ao_mapear (GSignalInvocationHint *dica, guint n, const GValue *valores, gpointer dados)
{
    GtkWidget *w = g_value_get_object (&valores[0]);

    if (!revelada && g_strcmp0 (G_OBJECT_TYPE_NAME (w), "XfcePanelWindow") == 0)
        opacidade_x (w, FALSE);
    return !revelada;
}

/* um plugin que entrou ou mudou de largura (a bandeja cresce a cada programa): espera de novo */
static gboolean
ao_alocar (GSignalInvocationHint *dica, guint n, const GValue *valores, gpointer dados)
{
    GtkWidget *w = g_value_get_object (&valores[0]);
    gint antes, agora;

    if (revelada)
        return FALSE;
    /* plugins de fora (socket) e a bandeja, que cresce a cada programa que põe ícone nela */
    if (!GTK_IS_SOCKET (w) && g_strcmp0 (G_OBJECT_TYPE_NAME (w), "SnBox") != 0
        && g_strcmp0 (G_OBJECT_TYPE_NAME (w), "XfceSystrayBox") != 0)
        return TRUE;
    antes = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (w), "codeos-largura"));
    agora = gtk_widget_get_allocated_width (w);
    if (agora != antes) {
        g_object_set_data (G_OBJECT (w), "codeos-largura", GINT_TO_POINTER (agora));
        recomecar_espera ();
    }
    return TRUE;
}

/* ── volume e notificações do tamanho do Windows ────────────────────────────────────────────── */

/* Os dois pedem um quadrado da altura da barra (40 px) com ícone de 32 px; aqui ficam com 24 px de
 * largura e ícone de 16 px, como os da bandeja. Eles refazem o tamanho quando a barra muda, então o
 * ajuste é reaplicado sempre que mudam. */
#define ICONE_BANDEJA   16
#define LARGURA_BANDEJA 24

static void encolher_imagens (GtkWidget *w, gpointer dados);

static void
imagem_mudou (GtkWidget *imagem)
{
    GtkImage *img = GTK_IMAGE (imagem);
    GdkPixbuf *grande = NULL, *pequeno;

    if (gtk_image_get_pixel_size (img) != ICONE_BANDEJA)
        gtk_image_set_pixel_size (img, ICONE_BANDEJA);
    /* o sino vem já desenhado em 32 px (superfície), e o tamanho do ícone não vale para ela */
    if (gtk_image_get_storage_type (img) == GTK_IMAGE_SURFACE) {
        cairo_surface_t *sup = NULL;
        g_object_get (img, "surface", &sup, NULL);
        if (sup != NULL && cairo_image_surface_get_width (sup) > ICONE_BANDEJA)
            grande = gdk_pixbuf_get_from_surface (sup, 0, 0, cairo_image_surface_get_width (sup),
                                                  cairo_image_surface_get_height (sup));
        if (sup != NULL)
            cairo_surface_destroy (sup);
    } else if (gtk_image_get_storage_type (img) == GTK_IMAGE_PIXBUF) {
        GdkPixbuf *pb = gtk_image_get_pixbuf (img);
        if (gdk_pixbuf_get_width (pb) > ICONE_BANDEJA)
            grande = g_object_ref (pb);
    }
    if (grande != NULL) {
        pequeno = gdk_pixbuf_scale_simple (grande, ICONE_BANDEJA, ICONE_BANDEJA, GDK_INTERP_HYPER);
        gtk_image_set_from_pixbuf (img, pequeno);
        g_object_unref (pequeno);
        g_object_unref (grande);
    }
}

static void
encolher_imagens (GtkWidget *w, gpointer dados)
{
    if (GTK_IS_IMAGE (w)) {
        imagem_mudou (w);
        if (g_object_get_data (G_OBJECT (w), MARCA) == NULL) {
            g_object_set_data (G_OBJECT (w), MARCA, GINT_TO_POINTER (1));
            g_signal_connect (w, "notify::pixel-size", G_CALLBACK (imagem_mudou), NULL);
            g_signal_connect (w, "notify::surface", G_CALLBACK (imagem_mudou), NULL);
            g_signal_connect (w, "notify::pixbuf", G_CALLBACK (imagem_mudou), NULL);
        }
    } else if (GTK_IS_CONTAINER (w)) {
        gtk_container_foreach (GTK_CONTAINER (w), encolher_imagens, NULL);
    }
}

static void
botao_mudou (GtkWidget *botao)
{
    gint largura, altura;

    gtk_widget_get_size_request (botao, &largura, &altura);
    if (largura != LARGURA_BANDEJA)
        gtk_widget_set_size_request (botao, LARGURA_BANDEJA, altura);
    encolher_imagens (botao, NULL);
}

static gboolean
achar_botao (GtkWidget *w, const gchar *nome)
{
    if (g_strcmp0 (gtk_widget_get_name (w), nome) == 0) {
        botao_mudou (w);
        g_signal_connect (w, "notify::width-request", G_CALLBACK (botao_mudou), NULL);
        g_signal_connect (w, "notify::height-request", G_CALLBACK (botao_mudou), NULL);
        /* o volume troca a imagem quando muda o volume ou o mudo */
        g_signal_connect_after (w, "style-updated", G_CALLBACK (encolher_imagens), NULL);
        return TRUE;
    }
    if (GTK_IS_CONTAINER (w)) {
        GList *filhos = gtk_container_get_children (GTK_CONTAINER (w));
        gboolean achou = FALSE;
        for (GList *i = filhos; i != NULL && !achou; i = i->next)
            achou = achar_botao (i->data, nome);
        g_list_free (filhos);
        return achou;
    }
    return FALSE;
}

/* Os ícones antigos não são botões: o ícone é uma janela do próprio programa dentro da bandeja, e nada
 * se acendia ao passar o mouse. A bandeja passa a desenhar atrás do ícone sob o mouse o mesmo realce dos
 * ícones novos (a altura toda da barra, a largura do ícone, branco a 8%). */
static void
mouse_no_icone (GtkWidget *icone, GdkEventCrossing *ev, gpointer entrou)
{
    g_object_set_data (G_OBJECT (icone), "codeos-sob-mouse", entrou);
    if (gtk_widget_get_parent (icone) != NULL)
        gtk_widget_queue_draw (gtk_widget_get_parent (icone));
}

static gboolean
realce_da_bandeja (GtkWidget *caixa, cairo_t *cr, gpointer dados)
{
    GtkAllocation ac, ai;
    GList *filhos = gtk_container_get_children (GTK_CONTAINER (caixa));

    gtk_widget_get_allocation (caixa, &ac);
    for (GList *i = filhos; i != NULL; i = i->next) {
        if (g_object_get_data (G_OBJECT (i->data), "codeos-sob-mouse") == NULL)
            continue;
        gtk_widget_get_allocation (i->data, &ai);
        cairo_set_source_rgba (cr, 1, 1, 1, 0.08);
        cairo_rectangle (cr, ai.x - (gtk_widget_get_has_window (caixa) ? 0 : ac.x), 0, ai.width, ac.height);
        cairo_fill (cr);
    }
    g_list_free (filhos);
    return FALSE;  /* os ícones são desenhados depois, por cima */
}

/* ícones antigos da bandeja (XEmbed): a bandeja põe só 2 px entre eles; com 4 px de cada lado ficam com
 * a mesma folga dos novos (4 px pelo CSS) */
static void
espacar_icone (GtkWidget *caixa, GtkWidget *icone)
{
    gtk_widget_set_margin_start (icone, 4);
    gtk_widget_set_margin_end (icone, 4);
    if (g_object_get_data (G_OBJECT (icone), MARCA) == NULL) {
        g_object_set_data (G_OBJECT (icone), MARCA, GINT_TO_POINTER (1));
        gtk_widget_add_events (icone, GDK_ENTER_NOTIFY_MASK | GDK_LEAVE_NOTIFY_MASK);
        g_signal_connect (icone, "enter-notify-event", G_CALLBACK (mouse_no_icone), GINT_TO_POINTER (1));
        g_signal_connect (icone, "leave-notify-event", G_CALLBACK (mouse_no_icone), NULL);
    }
}

static gboolean
achar_bandeja (GtkWidget *w)
{
    if (g_strcmp0 (G_OBJECT_TYPE_NAME (w), "XfceSystrayBox") == 0) {
        GList *filhos = gtk_container_get_children (GTK_CONTAINER (w));
        for (GList *i = filhos; i != NULL; i = i->next)
            espacar_icone (w, i->data);
        g_list_free (filhos);
        g_signal_connect (w, "add", G_CALLBACK (espacar_icone), NULL);
        g_signal_connect (w, "draw", G_CALLBACK (realce_da_bandeja), NULL);
        return TRUE;
    }
    if (GTK_IS_CONTAINER (w)) {
        GList *filhos = gtk_container_get_children (GTK_CONTAINER (w));
        gboolean achou = FALSE;
        for (GList *i = filhos; i != NULL && !achou; i = i->next)
            achou = achar_bandeja (i->data);
        g_list_free (filhos);
        return achou;
    }
    return FALSE;
}

static gboolean
encolher_plugin (gpointer nome)
{
    static gint tentativas = 0;  /* somadas as três buscas; os plugins aparecem nos primeiros segundos */
    GList *janelas = gtk_window_list_toplevels ();
    gboolean achou = FALSE;

    for (GList *i = janelas; i != NULL && !achou; i = i->next)
        achou = nome == NULL ? achar_bandeja (i->data) : achar_botao (i->data, nome);
    g_list_free (janelas);
    /* o plugin monta o botão logo depois de carregar: tenta por até 10 s */
    return achou || ++tentativas > 120 ? G_SOURCE_REMOVE : G_SOURCE_CONTINUE;
}

/* tira este módulo do GTK_MODULES, para os programas abertos pela barra não o herdarem */
static void
limpar_ambiente (void)
{
    const gchar *atual = g_getenv ("GTK_MODULES");
    gchar **partes;
    GPtrArray *resto;
    gchar *novo;

    if (atual == NULL)
        return;
    resto = g_ptr_array_new ();
    partes = g_strsplit (atual, ":", -1);
    for (gchar **p = partes; *p != NULL; p++)
        if (**p != '\0' && strstr (*p, "codeos-taskbar-pins") == NULL)
            g_ptr_array_add (resto, *p);
    g_ptr_array_add (resto, NULL);
    novo = g_strjoinv (":", (gchar **) resto->pdata);
    if (*novo == '\0')
        g_unsetenv ("GTK_MODULES");
    else
        g_setenv ("GTK_MODULES", novo, TRUE);
    g_free (novo);
    g_ptr_array_free (resto, TRUE);
    g_strfreev (partes);
}

G_MODULE_EXPORT void
gtk_module_init (gint *argc, gchar ***argv)
{
    gchar *linha = NULL;
    gsize tamanho = 0;

    limpar_ambiente ();
    /* plugins de fora da barra: wrapper-2.0 <módulo> <id> <socket> <nome> ... (o wrapper não passa os
     * argumentos ao gtk_init, então vêm do /proc) */
    if (g_file_get_contents ("/proc/self/cmdline", &linha, &tamanho, NULL)) {
        const gchar *arg[6] = { NULL };
        gsize n = 0;
        for (gsize i = 0; i < tamanho && n < G_N_ELEMENTS (arg); i += strlen (linha + i) + 1)
            arg[n++] = linha + i;
        if (n > 4 && g_str_has_suffix (arg[0], "wrapper-2.0")) {
            if (g_strcmp0 (arg[4], "pulseaudio") == 0)
                g_timeout_add (250, encolher_plugin, "pulseaudio-button");
            else if (g_strcmp0 (arg[4], "systray") == 0)
                g_timeout_add (250, encolher_plugin, NULL);
            else if (g_strcmp0 (arg[4], "notification-plugin") == 0)
                g_timeout_add (250, encolher_plugin, "xfce4-notification-plugin");
            g_free (linha);
            return;
        }
        g_free (linha);
    }
    if (g_strcmp0 (g_get_prgname (), "xfce4-panel") != 0)
        return;
    /* o botão iniciar, a bandeja, o volume, o sino e os genmon rodam dentro da barra (o CodeOS marca os
     * plugins como internos): o volume, o sino e a bandeja são acertados aqui mesmo */
    g_timeout_add (250, encolher_plugin, "pulseaudio-button");
    g_timeout_add (250, encolher_plugin, "xfce4-notification-plugin");
    g_timeout_add (250, encolher_plugin, NULL);
    g_signal_add_emission_hook (g_signal_lookup ("map", GTK_TYPE_WIDGET), 0, ao_mapear, NULL, NULL);
    g_signal_add_emission_hook (g_signal_lookup ("add", GTK_TYPE_CONTAINER), 0, ao_acrescentar, NULL, NULL);
    g_signal_add_emission_hook (g_signal_lookup ("size-allocate", GTK_TYPE_WIDGET), 0, ao_alocar, NULL, NULL);
    recomecar_espera ();
    g_timeout_add (ESPERA_MAXIMA, revelar, GINT_TO_POINTER (1));
    g_idle_add (iniciar, NULL);
}
