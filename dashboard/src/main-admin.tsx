import { start } from './boot-screen.tsx';
import { AppProvider } from './ui/kit.tsx';
import { AdminApp } from './admin/App.tsx';

start((sb) => <AppProvider sb={sb} initial={{ userId: sb.people.root.id, context: 'aal2' }}><AdminApp /></AppProvider>);
