/*
 * This implements a single data-window feeder with a memory based backing,
 * though used / written for the file-sense structure, it should be trivially
 * re-usable by other implementations.
 */

struct fsense_thdata {
	struct senseye_ch* ch;
	uint8_t* fmap;
	size_t sz;
	size_t ofs;
	bool wrap;
	int ind;

	size_t bytes_perline;
	size_t small_step;
	size_t large_step;

	int pipe_in;
	int pipe_out;
};

/* repopulate the channel */
static void refresh_data(struct fsense_thdata* th, size_t pos)
{
	struct rwstat_ch* ch = th->ch->in;
	size_t nb = ch->row_size(ch);
	struct arcan_shmif_cont* cont = ch->context(ch);
	size_t ntw = nb * cont->h;

/* send our new position to the preview- window */
	write(th->pipe_out, &pos, sizeof(size_t));

/* tell the channel about our new position */
	ch->wind_ofs(ch, pos);

/* and populate / feed it to the channel */
	int ign;
	size_t left = th->sz - pos;
	if (ntw > left){
		ch->data(ch, th->fmap + pos, left, &ign);
		if (th->wrap)
			ch->data(ch, th->fmap, ntw - left, &ign);
		else
			ch->data(ch, NULL, ntw - left, &ign);
	}
	else
		ch->data(ch, th->fmap + pos, ntw, &ign);
}

/* post-seek: adjust the current position based on wrapping, block size etc. */
static size_t fix_ofset(ssize_t ofs, size_t map_sz, bool wrap)
{
	if (ofs > map_sz){
		if (wrap)
			ofs = 0;
		else
			ofs = map_sz;
	}

	return ofs;
}

/* synch the current active position / ofset for the current view */
static void set_position(struct fsense_thdata* th, size_t pos, size_t align)
{
	if (align > 0)
		if (th->ofs % align != 0)
			th->ofs = fix_ofset(th->ofs - (th->ofs % align), th->sz, th->wrap);
}

static void register_bindings(struct arcan_shmif_cont* cont)
{
/* rwstat provides most basic bindings, reserved for future use */
}

static void process_label(struct fsense_thdata* thd,
	struct rwstat_ch* ch, const char* lbl)
{
/* rwstat provides most basic bindings, reserved for future use */
}

static bool process_cmd(
	struct fsense_thdata* thd, struct rwstat_ch* ch, struct arcan_tgtevent* tgt)
{
	switch(tgt->kind){
	case TARGET_COMMAND_DISPLAYHINT:{
		size_t base = tgt->ioevs[0].iv;
		if (base > 0 && (base & (base - 1)) == 0 &&
			arcan_shmif_resize(ch->context(ch), base, base)){
			ch->resize(ch, base);
/* we also need to check ofs against this new block-size,
 * and possible update the hinted number of lines covered
 * by the buffer */
		}
	}
	break;

#define FIXOFS(ofs) fix_ofset(ofs, thd->sz, thd->wrap)

	case TARGET_COMMAND_SEEKTIME:{
		thd->ofs = FIXOFS(tgt->ioevs[1].iv);
		refresh_data(thd, thd->ofs);
	}

	case TARGET_COMMAND_STEPFRAME:{
		if (tgt->ioevs[0].iv == -1 || tgt->ioevs[0].iv == 1){
			thd->ofs = FIXOFS(thd->ofs + thd->small_step * tgt->ioevs[0].iv);
			refresh_data(thd, thd->ofs);
		}
		else if (tgt->ioevs[0].iv == 0){
			refresh_data(thd, thd->ofs);
		}
		else if (tgt->ioevs[0].iv == -2 || tgt->ioevs[0].iv == 2){
			thd->ofs = FIXOFS(thd->ofs +
				(ch->row_size(ch) *
				(ch->context(ch)->h) >> thd->large_step) *
				(tgt->ioevs[0].iv == -2 ? -1 : 1)
			);
			refresh_data(thd, thd->ofs);
		}
	}

	case TARGET_COMMAND_EXIT:
		return false;
	break;
	default:
	break;
	}
	return true;
}

/* may be run in a new thread or a new process, don't know, don't care */
void* data_window_loop(void* th_data)
{
/* we ignore the senseye- abstraction here and works
 * directly with the rwstat and shmif context */
	struct fsense_thdata* thd = th_data;
	struct rwstat_ch* ch = thd->ch->in;
	struct arcan_shmif_cont* cont = ch->context(ch);

	arcan_event ev = {
		.category = EVENT_EXTERNAL,
		.ext.kind = ARCAN_EVENT(IDENT),
		.ext.message.data = "fsense"
	};
	ch->event(ch, &ev);

	register_bindings(cont);
	short pollev = POLLIN | POLLERR | POLLHUP | POLLNVAL;
	ch->switch_clock(ch, RW_CLK_BLOCK);
	thd->small_step = ch->row_size(ch);
	refresh_data(thd, thd->ofs);

	int evstat = 0;
	while (evstat != -1){
		struct pollfd fds[2] = {
			{	.fd = thd->pipe_in, .events = pollev },
			{ .fd = cont->epipe, .events = pollev }
		};

		int sv = poll(fds, 2, -1);

/* parent controlled offset */
		if ( (fds[0].revents & POLLIN) ){
			size_t lofs;
			read(fds[0].fd, &lofs, sizeof(size_t));
			refresh_data(thd, lofs);
		}

/* flush data window event queue */
		arcan_event ev;
		while ( (evstat = arcan_shmif_poll(cont, &ev)) > 0){

/* shared rwstat handler? */
			if (rwstat_consume_event(ch, &ev))
				continue;

			if (ev.category == EVENT_IO)
				process_label(thd, ch, ev.io.label);

			if (ev.category == EVENT_TARGET)
				process_cmd(thd, ch, &ev.tgt);
		}
	}

	return NULL;
}
