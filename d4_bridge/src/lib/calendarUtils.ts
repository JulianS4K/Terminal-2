import * as ics from 'ics';
import { Event } from '../types';
import { publicUrl } from './utils';

export const generateGoogleCalendarLink = (event: Event) => {
  const start = new Date(event.date.seconds * 1000).toISOString().replace(/-|:|\.\d\d\d/g, "");
  const end = new Date((event.date.seconds + 7200) * 1000).toISOString().replace(/-|:|\.\d\d\d/g, ""); // Assume 2 hours
  
  return `https://www.google.com/calendar/render?action=TEMPLATE&text=${encodeURIComponent(event.title)}&dates=${start}/${end}&details=${encodeURIComponent(event.description)}&location=${encodeURIComponent(event.location)}&sf=true&output=xml`;
};

export const downloadIcsFile = (event: Event) => {
  const date = new Date(event.date.seconds * 1000);
  const icsEvent: ics.EventAttributes = {
    start: [date.getFullYear(), date.getMonth() + 1, date.getDate(), date.getHours(), date.getMinutes()],
    duration: { hours: 2, minutes: 0 },
    title: event.title,
    description: event.description,
    location: event.location,
    url: publicUrl('event/' + event.id),
    categories: [event.category],
    status: 'CONFIRMED',
    busyStatus: 'BUSY'
  };

  ics.createEvent(icsEvent, (error, value) => {
    if (error) {
      console.error(error);
      return;
    }
    const blob = new Blob([value], { type: 'text/calendar;charset=utf-8' });
    const url = window.URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.setAttribute('download', `${event.title.replace(/\s+/g, '_')}.ics`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  });
};
